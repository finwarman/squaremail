import AppKit
import WebKit
import ClassicKit

enum HTMLPolicy {
    static let contentPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src squaremail-image:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; media-src 'none'; font-src 'none'"

    static func document(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentPolicy)">
        <meta name="color-scheme" content="light">
        <style>
        html { background:white; color:#161616; }
        body { font:14px/1.65 Tahoma,Verdana,sans-serif; margin:28px 34px; overflow-wrap:anywhere; }
        h1 { font-size:30px; line-height:1.2; font-weight:normal; }
        h2 { font-size:21px; } blockquote { border-left:3px solid #a6caf0; margin:24px 0; padding:8px 18px; color:#555; }
        a { color:#0a246a; } table { max-width:100%; border-spacing:0!important; }
        table,thead,tbody,tfoot,tr,td,th { height:auto!important; min-height:0!important; width:auto!important; }
        td,th { padding:0!important; } img { max-width:100%; height:auto; } pre { white-space:pre-wrap; }
        hr { border:0; border-top:1px solid #d4d0c8; margin:18px 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func permitsLink(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }
}

final class ReaderView: NSView, WKNavigationDelegate {
    private enum Spacing: String { case original, compact }
    private let spacingButton = ClassicButton("Compact spacing", style: .toggle)
    private var spacing: Spacing = WindowPresentation.isBackground ? .original : (Spacing(rawValue: UserDefaults.standard.string(forKey: "readerSpacing") ?? "") ?? .original)
    private let mediaBar = ClassicPanel()
    private let imagesButton = ClassicButton("Load images")
    private let attachmentsButton = ClassicButton("Attachments")
    private let mediaLabel = NSTextField(labelWithString: "Remote images blocked")
    private let attachments = AttachmentPanel()
    private let imageHandler = ImageSchemeHandler()
    private var imageHTML: String?
    private var imagePermission: ImagePermission = .blocked
    var onLoadImages: ((Mail) -> Void)?
    var onAttachments: ((Mail) -> Void)?
    var onPreview: ((MediaAsset, Mail) -> Void)?
    var onOpenPreview: ((MediaAsset, Mail) -> Void)?
    var onMediaReset: (() -> Void)?
    var onImageState: ((ImagePermission) -> Void)?
    private let scroll = NSScrollView()
    // TextKit 1 avoids full-paragraph GPU surfaces for long plain-text messages.
    private let text = NSTextView(usingTextLayoutManager: false)
    private var web: WKWebView?
    private var rendered = ""
    private var mode: ReaderMode = .text
    private var message: Mail?
    private var idleTask: Task<Void, Never>?
    private var navigation: WKNavigation?
    private var finished: WKNavigation?
    private var htmlWaiter: CheckedContinuation<Void, Error>?
    private static let textLayoutThreshold = 64 * 1024
    private static let htmlIdleDelay: Duration = .seconds(5)
    var hasHTMLRenderer: Bool { web != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.font = ClassicTheme.font(14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        text.defaultParagraphStyle = paragraph
        text.textColor = ClassicTheme.ink
        text.backgroundColor = .white
        text.textContainerInset = NSSize(width: 30, height: 24)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.usesFindBar = true
        scroll.documentView = text
        addSubview(scroll)
        addSubview(mediaBar)
        for view in [imagesButton, attachmentsButton, mediaLabel, spacingButton] { mediaBar.addSubview(view) }
        mediaLabel.font = ClassicTheme.font(10)
        mediaLabel.textColor = ClassicTheme.muted
        imagesButton.toolTip = "Load up to 12 images for this message. Remote servers may learn that you opened it."
        imagesButton.onPress = { [weak self] in
            guard let self, let message = self.message else { return }
            if self.imagePermission == .loaded { self.hideImages(); return }
            self.onLoadImages?(message)
        }
        attachmentsButton.onPress = { [weak self] in
            guard let self, let message = self.message else { return }
            if !self.attachments.isHidden { self.attachments.isHidden = true; self.needsLayout = true; return }
            self.onAttachments?(message)
        }
        spacingButton.toolTip = "Plain text: reduce repeated blank lines while keeping indentation, bullets and quote separators. Stored mail is unchanged."
        spacingButton.onPress = { [weak self] in
            guard let self, let message else { return }
            spacing = spacing == .original ? .compact : .original
            if !WindowPresentation.isBackground { UserDefaults.standard.set(spacing.rawValue, forKey: "readerSpacing") }
            rendered = ""; display(message, mode: mode)
        }
        attachments.isHidden = true
        attachments.onPreview = { [weak self] asset in
            guard let self, let message = self.message else { return }
            self.onPreview?(asset, message)
        }
        attachments.onOpen = { [weak self] asset in
            guard let self, let message = self.message else { return }
            self.onOpenPreview?(asset, message)
        }
        addSubview(attachments)
        showNotice("Select a message to read it.")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        let narrow = bounds.width < 560
        let barHeight: CGFloat = message == nil ? 0 : (narrow ? 62 : 34)
        let attachmentHeight: CGFloat = attachments.isHidden ? 0 : min(150, max(0, bounds.height - barHeight) / 2)
        mediaBar.isHidden = message == nil
        mediaBar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        imagesButton.frame = NSRect(x: 7, y: 5, width: 102, height: 24)
        attachmentsButton.frame = NSRect(x: 116, y: 5, width: 100, height: 24)
        spacingButton.frame = NSRect(x: narrow ? 7 : bounds.width - 140, y: narrow ? 33 : 5, width: 132, height: 24)
        mediaLabel.frame = NSRect(x: narrow ? 148 : 226, y: narrow ? 36 : 8, width: max(0, bounds.width - (narrow ? 154 : 375)), height: 18)
        let content = NSRect(x: 0, y: attachmentHeight, width: bounds.width, height: max(0, bounds.height - barHeight - attachmentHeight))
        scroll.frame = content
        web?.frame = content
        attachments.frame = NSRect(x: 0, y: 0, width: bounds.width, height: attachmentHeight)
        text.setFrameSize(NSSize(width: bounds.width, height: max(bounds.height, text.frame.height)))
    }

    func display(_ mail: Mail, mode: ReaderMode) {
        if message?.id != mail.id { resetMedia() }
        if mode == .text { onMediaReset?() }
        message = mail
        self.mode = mode
        onImageState?(imagePermission)
        spacingButton.isEnabled = mode == .text
        spacingButton.state = spacing == .compact ? .on : .off
        imagesButton.isEnabled = mode == .html
        needsLayout = true
        if mode == .text {
            queueHTMLRelease()
            web?.isHidden = true
            scroll.isHidden = false
            showText(spacing == .compact ? CompactText.render(mail.text ?? "This message is not cached. Sync and open it while online.") : (mail.text ?? "This message is not cached. Sync and open it while online."))
            return
        }
        guard let html = mail.html, !html.isEmpty else {
            queueHTMLRelease()
            web?.isHidden = true
            scroll.isHidden = false
            showText(mail.text ?? "This message has no cached HTML body.")
            return
        }
        scroll.isHidden = true
        idleTask?.cancel()
        if let web { web.isHidden = false; load(imageHTML ?? html); return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(imageHandler, forURLScheme: ImageSchemeHandler.scheme)
        let view = WKWebView(frame: scroll.frame, configuration: configuration)
        view.navigationDelegate = self
        addSubview(view)
        web = view
        // CSP and sanitization are active before the additional WebKit network rule arrives.
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "SquareMail.BlockResources.v1", encodedContentRuleList: rules) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self, let web = self.web, let list else { return }
                web.configuration.userContentController.add(list)
                if self.mode == .html, let html = self.message?.html { self.load(self.imageHTML ?? html) }
            }
        }
        load(imageHTML ?? html)
    }

    func showNotice(_ notice: String) {
        resetMedia()
        message = nil
        web?.isHidden = true
        scroll.isHidden = false
        showText(notice)
        queueHTMLRelease()
        needsLayout = true
    }

    private func resetMedia() {
        onMediaReset?()
        web?.stopLoading()
        htmlWaiter?.resume(throwing: CancellationError())
        htmlWaiter = nil
        navigation = nil
        finished = nil
        rendered = ""
        imageHTML = nil
        _ = imageHandler.replace([:])
        imagePermission = .blocked
        imagesButton.title = "Load images"
        imagesButton.setAccessibilityLabel(imagesButton.title)
        onImageState?(.blocked)
        mediaLabel.stringValue = "Remote images blocked"
        attachments.show([])
        attachments.isHidden = true
    }

    func mediaStatus(_ value: String) { mediaLabel.stringValue = value; mediaLabel.toolTip = value }

    func showImages(_ html: String, files: [String: URL]) {
        guard mode == .html else { return }
        web?.stopLoading()
        let prefix = imageHandler.replace(files)
        imageHTML = html.replacingOccurrences(of: "squaremail-image://asset/", with: prefix)
        imagePermission = .loaded
        imagesButton.title = "Hide images"
        imagesButton.setAccessibilityLabel(imagesButton.title)
        imagesButton.needsDisplay = true
        onImageState?(.loaded)
        load(imageHTML!)
    }

    private func hideImages() {
        onMediaReset?()
        web?.stopLoading()
        _ = imageHandler.replace([:])
        imageHTML = nil
        imagePermission = .blocked
        imagesButton.title = "Load images"
        imagesButton.setAccessibilityLabel(imagesButton.title)
        imagesButton.needsDisplay = true
        onImageState?(.blocked)
        mediaStatus("Remote images blocked")
        if let html = message?.html { load(html) }
    }

    func showAttachments(_ assets: [MediaAsset]) {
        attachments.show(assets)
        let count = assets.filter { $0.source.kind != .remote }.count
        attachments.isHidden = count == 0
        mediaStatus(count == 0 ? "No attachments found." : "\(count) attachments · previews download on request · max 32 shown")
        needsLayout = true
    }

    func showPreview(_ image: NSImage, asset: MediaAsset) {
        attachments.showPreview(image, asset: asset)
        mediaStatus("Thumbnail cached · \(asset.name)")
    }

    func verifyImages(_ expected: Int) throws {
        guard imageHandler.delivered == expected else { throw MailError(message: "Local image delivery count mismatch: \(imageHandler.delivered), expected \(expected). \(mediaLabel.stringValue)") }
    }

    func finishImages(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while imageHandler.delivered < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try verifyImages(expected)
    }

    private func queueHTMLRelease() {
        idleTask?.cancel()
        guard web != nil else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.htmlIdleDelay) } catch { return }
            guard let self, self.mode == .text || self.message?.html?.isEmpty != false || self.isHiddenOrHasHiddenAncestor else { return }
            self.web?.stopLoading()
            self.web?.navigationDelegate = nil
            self.web?.removeFromSuperview()
            self.web = nil
            self.navigation = nil
            self.finished = nil
            self.rendered = ""
            self.htmlWaiter?.resume(throwing: CancellationError())
            self.htmlWaiter = nil
        }
    }

    func pause() { onMediaReset?(); queueHTMLRelease() }

    func finishHTML() async throws {
        guard mode == .html, let navigation, finished !== navigation else { return }
        try await withCheckedThrowingContinuation { htmlWaiter = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        finished = navigation
        htmlWaiter?.resume()
        htmlWaiter = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failHTML(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failHTML(navigation, error)
    }

    private func failHTML(_ navigation: WKNavigation?, _ error: Error) {
        guard navigation === self.navigation else { return }
        htmlWaiter?.resume(throwing: error)
        htmlWaiter = nil
    }

    private func showText(_ value: String) {
        text.layoutManager?.allowsNonContiguousLayout = value.utf8.count > Self.textLayoutThreshold
        text.string = value
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollToBeginningOfDocument(nil)
    }

    func verifyText(_ expected: String) throws {
        guard text.string == expected else { throw MailError(message: "Plain text content changed during display") }
        let selection = text.selectedRange()
        let responder = window?.firstResponder
        window?.makeFirstResponder(text)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            text.setSelectedRange(selection)
            text.scrollToBeginningOfDocument(nil)
            if let responder { window?.makeFirstResponder(responder) }
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        text.selectAll(nil)
        let written = text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes)
        let copied = pasteboard.string(forType: .string)
        guard written, copied == expected else {
            throw MailError(message: "Native text copy failed: selection \(text.selectedRange().length), expected \(expected.utf16.count), copied \(copied?.utf16.count ?? -1), written \(written)")
        }
        text.scrollToEndOfDocument(nil)
        if text.frame.height > scroll.contentSize.height + 1, scroll.contentView.bounds.origin.y <= 0 {
            throw MailError(message: "Native text scrolling did not reach the body")
        }
    }

    private func load(_ html: String) {
        guard rendered != html else { return }
        rendered = html
        htmlWaiter?.resume(throwing: CancellationError())
        htmlWaiter = nil
        finished = nil
        navigation = web?.loadHTMLString(HTMLPolicy.document(html), baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated, HTMLPolicy.permitsLink(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

extension ReaderView {
    func verifySpacing() throws {
        let sample = "\n \nIntro\n\n\n- one\n  - nested\n\n> Reply\n> > Earlier\n------\n\n"
        let expected = "Intro\n\n- one\n  - nested\n\n> Reply\n> > Earlier\n------"
        guard CompactText.render(sample) == expected else { throw MailError(message: "Compact spacing damaged hierarchy or separators") }
        guard let original = message?.text, mode == .text else { throw MailError(message: "Spacing control needs a plain-text fixture") }
        spacingButton.performClick(nil)
        guard text.string == CompactText.render(original), spacingButton.state == .on, message?.text == original else { throw MailError(message: "Compact spacing changed stored mail") }
        spacingButton.performClick(nil)
        guard text.string == original, spacingButton.state == .off else { throw MailError(message: "Original spacing did not restore") }
    }
}
