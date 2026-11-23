import AppKit
import WebKit
import ClassicKit
import MessageText

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
        img:not([src]) { display:inline-block; width:112px!important; height:20px!important; font:11px/20px Tahoma,Verdana,sans-serif; color:#666; background:#eee; vertical-align:middle; }
        hr { border:0; border-top:1px solid #d4d0c8; margin:18px 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func permitsLink(_ url: URL) -> Bool {
        PlainRenderer.permits(url)
    }
}

final class ReaderView: NSView, WKNavigationDelegate, NSTextViewDelegate {
    private let spacingButton = ClassicButton("", icon: .spacing, style: .iconToggle)
    private var spacing: TextSpacing = WindowPresentation.isBackground ? .original : (TextSpacing(rawValue: UserDefaults.standard.string(forKey: "readerSpacing") ?? "") ?? .original)
    private let linksButton = ClassicButton("", icon: .link, style: .iconToggle)
    private var modeButtons: [ClassicButton] = []
    private let modeGroup: ClassicPanel = { let panel = ClassicPanel(); panel.edge = .sunken; return panel }()
    private var linkStyle: LinkStyle = WindowPresentation.isBackground ? .readable : (LinkStyle(rawValue: UserDefaults.standard.string(forKey: "readerLinks") ?? "") ?? .readable)
    private var textTask: Task<Void, Never>?
    private var textRevision = 0
    var onLink: ((URL, Mail?) -> Void)?
    private let mediaBar = ClassicPanel()
    private let imagesButton = ClassicButton("Load images")
    private let attachmentsButton = ClassicButton("Attachments")
    private let mediaLabel = NSTextField(labelWithString: "Remote images blocked")
    private let progress = ClassicProgress()
    private let cancelLoad = ClassicButton("Cancel")
    private let retryLoad = ClassicButton("Retry")
    var onCancelLoad: (() -> Void)?
    var onRetryLoad: (() -> Void)?
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
    var onReady: ((String?) -> Void)?
    private(set) var readyID: String?
    private let scroll = NSScrollView()
    // TextKit 1 avoids full-paragraph GPU surfaces for long plain-text messages.
    private let text = MailTextView(usingTextLayoutManager: false)
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
        text.delegate = self
        text.linkTextAttributes = [.foregroundColor: ClassicTheme.color(0x0000CC), .underlineStyle: NSUnderlineStyle.single.rawValue]
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
        for view in [imagesButton, attachmentsButton, mediaLabel, spacingButton, linksButton, progress, cancelLoad, retryLoad] { mediaBar.addSubview(view) }
        cancelLoad.isHidden = true; retryLoad.isHidden = true
        cancelLoad.onPress = { [weak self] in self?.onCancelLoad?() }
        retryLoad.onPress = { [weak self] in self?.onRetryLoad?() }
        mediaLabel.font = ClassicTheme.font(10)
        mediaLabel.textColor = ClassicTheme.muted
        imagesButton.toolTip = "Load up to 12 images for this message. Remote servers may learn that you opened it."
        attachmentsButton.toolTip = "Show attachment metadata. Previews download only when requested."
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
        linksButton.toolTip = "Short labels with full destinations on hover. Copy retains full links. No hover requests."
        linksButton.setAccessibilityLabel("Readable links")
        spacingButton.setAccessibilityLabel("Compact spacing")
        linksButton.onPress = { [weak self] in
            guard let self, let message else { return }
            linkStyle = linkStyle == .original ? .readable : .original
            if !WindowPresentation.isBackground { UserDefaults.standard.set(linkStyle.rawValue, forKey: "readerLinks") }
            display(message, mode: mode)
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

    func setModeButtons(_ plain: ClassicButton, html: ClassicButton) {
        modeButtons = [plain, html]
        mediaBar.addSubview(modeGroup)
        for button in modeButtons { modeGroup.addSubview(button) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let narrow = bounds.width < 690
        let loading = progress.state != .idle
        let barHeight: CGFloat = message == nil && !loading && retryLoad.isHidden ? 0 : (narrow ? 64 : 34) + (loading ? 16 : 0)
        let attachmentHeight: CGFloat = attachments.isHidden ? 0 : min(150, max(0, bounds.height - barHeight) / 2)
        mediaBar.isHidden = barHeight == 0
        mediaBar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        imagesButton.frame = NSRect(x: 7, y: 5, width: 102, height: 24)
        attachmentsButton.frame = NSRect(x: 116, y: 5, width: 100, height: 24)
        let groupWidth: CGFloat = 244
        let groupX: CGFloat = narrow ? 7 : bounds.width - groupWidth - 7
        let groupY: CGFloat = narrow ? 35 : 4
        modeGroup.frame = NSRect(x: groupX, y: groupY, width: 164, height: 26)
        for (index, button) in modeButtons.enumerated() { button.frame = NSRect(x: 2 + CGFloat(index * 80), y: 2, width: 80, height: 22) }
        spacingButton.frame = NSRect(x: groupX + 172, y: groupY + 1, width: 32, height: 24)
        linksButton.frame = NSRect(x: groupX + 208, y: groupY + 1, width: 32, height: 24)
        let labelStart: CGFloat = loading || !retryLoad.isHidden ? 304 : 226
        mediaLabel.frame = NSRect(x: narrow ? groupWidth + 16 : labelStart, y: narrow ? 38 : 8, width: max(0, narrow ? bounds.width - groupWidth - 23 : groupX - labelStart - 8), height: 18)
        cancelLoad.frame = NSRect(x: 223, y: 5, width: 70, height: 24)
        retryLoad.frame = cancelLoad.frame
        progress.isHidden = !loading
        progress.frame = NSRect(x: 7, y: narrow ? 64 : 34, width: max(0, bounds.width - 14), height: 12)
        let content = NSRect(x: 0, y: attachmentHeight, width: bounds.width, height: max(0, bounds.height - barHeight - attachmentHeight))
        scroll.frame = content
        web?.frame = content
        attachments.frame = NSRect(x: 0, y: 0, width: bounds.width, height: attachmentHeight)
        text.setFrameSize(NSSize(width: bounds.width, height: max(bounds.height, text.frame.height)))
    }

    func display(_ mail: Mail, mode: ReaderMode) {
        readyID = nil; onReady?(nil)
        if message?.id != mail.id { resetMedia() }
        if mode == .text { onMediaReset?() }
        message = mail
        retryLoad.isHidden = true
        self.mode = mode
        onImageState?(imagePermission)
        linksButton.isEnabled = mode == .text
        linksButton.state = linkStyle == .readable ? .on : .off
        linksButton.toolTip = linkStyle == .readable ? "Readable links on. Click to show original URL text. Hover links for full targets; copying keeps full URLs." : "Readable links off. Click to shorten email/Markdown links and long URLs."
        spacingButton.isEnabled = mode == .text
        spacingButton.state = spacing == .compact ? .on : .off
        spacingButton.toolTip = spacing == .compact ? "Compact spacing on. Click to restore original spacing." : "Compact spacing off. Click to reduce blank lines, invisible padding and prose gutters, preserving lists and quotes."
        imagesButton.isEnabled = mode == .html && progress.state == .idle
        attachmentsButton.isEnabled = progress.state == .idle
        needsLayout = true
        if mode == .text {
            queueHTMLRelease()
            web?.isHidden = true
            scroll.isHidden = false
            showText(mail.text ?? "This message is not cached. Sync and open it while online.")
            return
        }
        guard let html = mail.html, !html.isEmpty else {
            queueHTMLRelease()
            web?.isHidden = true
            scroll.isHidden = false
            showText(mail.text ?? "This message has no cached HTML body.")
            return
        }
        cancelText()
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
        readyID = nil; onReady?(nil)
        resetMedia()
        message = nil
        retryLoad.isHidden = true
        for button in [imagesButton, attachmentsButton, spacingButton, linksButton] { button.isEnabled = false }
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
        mediaProgress(.idle)
        imagesButton.title = "Load images"
        imagesButton.setAccessibilityLabel(imagesButton.title)
        onImageState?(.blocked)
        mediaLabel.stringValue = "Remote images blocked"
        attachments.show([])
        attachments.isHidden = true
    }

    func mediaStatus(_ value: String) { mediaLabel.stringValue = value; mediaLabel.toolTip = value }
    func mediaProgress(_ state: ClassicProgress.State) {
        progress.state = state
        cancelLoad.isHidden = state == .idle
        imagesButton.isEnabled = state == .idle && message != nil && mode == .html
        attachmentsButton.isEnabled = state == .idle && message != nil
        needsLayout = true
    }
    func showLoading(_ value: String) {
        showNotice(value); mediaStatus(value); mediaProgress(.indeterminate)
    }
    func showUnavailable(_ value: String) {
        showNotice(value); mediaStatus("Message unavailable. Retry when online.")
        retryLoad.isHidden = false; needsLayout = true
    }

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

    func pause() { readyID = nil; onReady?(nil); cancelText(); onMediaReset?(); queueHTMLRelease() }

    func finishHTML() async throws {
        guard mode == .html, let navigation, finished !== navigation else { return }
        try await withCheckedThrowingContinuation { htmlWaiter = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        finished = navigation
        if mode == .html, !webView.isHidden { readyID = message?.id; onReady?(readyID) }
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
        cancelText(); let revision = textRevision
        text.document = nil
        text.string = ""; text.setSelectedRange(NSRange(location: 0, length: 0))
        let spacing = message == nil ? TextSpacing.original : spacing
        let links = message == nil ? LinkStyle.original : linkStyle
        let html = message?.html
        textTask = Task { [weak self] in
            do {
                let document = try await PlainRenderer.shared.render(value, spacing: spacing, links: links, html: html)
                guard let self, !Task.isCancelled, textRevision == revision else { return }
                let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = spacing == .compact ? 2 : 5
                let body = NSMutableAttributedString(string: document.text, attributes: [.font: ClassicTheme.font(14), .foregroundColor: ClassicTheme.ink, .paragraphStyle: paragraph])
                for link in document.links { body.addAttributes([.link: link.url, .toolTip: link.tooltip], range: link.range) }
                text.layoutManager?.allowsNonContiguousLayout = document.text.utf8.count > Self.textLayoutThreshold
                text.textStorage?.setAttributedString(body); text.document = document
                text.scrollToBeginningOfDocument(nil)
                readyID = message?.id; onReady?(readyID)
            } catch is CancellationError {} catch {
                guard let self, textRevision == revision else { return }
                text.string = value
                readyID = message?.id; onReady?(readyID)
            }
        }
    }
    private func cancelText() {
        textRevision += 1
        textTask?.cancel(); textTask = nil
    }
    func finishText() async { await textTask?.value }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, PlainRenderer.permits(url) else { return true }
        onLink?(url, message); return true
    }

    func verifyText(_ expected: String) throws {
        guard text.document?.copyText(NSRange(location: 0, length: text.string.utf16.count)) == expected else { throw MailError(message: "Plain text content changed during display") }
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
            onLink?(url, message)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

extension ReaderView {
    func verifyControlLayout() throws {
        guard message != nil else { return }
        let controls = [modeGroup, spacingButton, linksButton, imagesButton, attachmentsButton]
        guard modeButtons.count == 2, controls.allSatisfy({ mediaBar.bounds.contains($0.frame) }),
              modeButtons.allSatisfy({ modeGroup.bounds.contains($0.frame) && !$0.title.isEmpty && $0.toolTip?.isEmpty == false }),
              [spacingButton, linksButton].allSatisfy({ $0.frame.width == 32 && $0.accessibilityLabel()?.isEmpty == false }) else { throw MailError(message: "Grouped reader controls lost bounds, labels or help") }
        for (index, button) in controls.enumerated() {
            guard controls.dropFirst(index + 1).allSatisfy({ !button.frame.intersects($0.frame) }) else { throw MailError(message: "Reader controls overlap") }
        }
    }

    func verifyLoading() async throws {
        let saved = message
        let cancel = onCancelLoad; let retry = onRetryLoad
        defer { onCancelLoad = cancel; onRetryLoad = retry; if let saved { display(saved, mode: .text) } }
        var cancelled = 0; var retried = 0
        onCancelLoad = { cancelled += 1 }; onRetryLoad = { retried += 1 }
        showLoading("Downloading sample message…")
        guard progress.state == .indeterminate, !cancelLoad.isHidden, !imagesButton.isEnabled, !attachmentsButton.isEnabled else { throw MailError(message: "Loading controls have stale enabled states") }
        cancelLoad.performClick(nil)
        guard cancelled == 1 else { throw MailError(message: "Cancel loading did not dispatch") }
        showUnavailable("Sample unavailable")
        guard progress.state == .idle, cancelLoad.isHidden, !retryLoad.isHidden else { throw MailError(message: "Failed loading retained progress or lost Retry") }
        retryLoad.performClick(nil)
        guard retried == 1 else { throw MailError(message: "Retry loading did not dispatch") }
        mediaProgress(.determinate(completed: 1, total: 3))
        guard progress.accessibilityValue() as? String == "1 of 3" else { throw MailError(message: "Known image progress changed its total") }
        showNotice("Done")
        guard progress.state == .idle, retryLoad.isHidden, cancelLoad.isHidden else { throw MailError(message: "Progress survived selection reset") }
        await finishText()
    }

    func verifyLinks() async throws {
        let saved = message
        let callback = onLink
        defer { onLink = callback; if let saved { display(saved, mode: .text) } }
        let source = "😀 Survey<https://gbr01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.test%2Fsurvey&data=synthetic>\n[Details](https://example.test/details)"
        let mail = Mail(id: "link-fixture", pinned: false, keepUnread: false, accountId: "demo", remoteId: "links", sender: "Sample", senderAddress: "sample@example.test", recipient: "reader@example.test", subject: "Link fixture", preview: "Sample", timestamp: 0, unread: false, starred: false, hasAttachments: false, text: source, html: "<p>Before the blocked image</p><img alt=\"Image blocked\"><p>After the blocked image</p>")
        display(mail, mode: .text); await finishText()
        guard let document = text.document, document.links.count == 2, let link = document.links.first,
              text.textStorage?.attribute(.link, at: link.range.location, effectiveRange: nil) as? URL == link.url,
              text.textStorage?.attribute(.toolTip, at: link.range.location, effectiveRange: nil) as? String == link.tooltip else { throw MailError(message: "Native readable link attributes missing") }
        try verifyText(source)
        var clicked: URL?
        onLink = { url, _ in clicked = url }
        _ = textView(text, clickedOnLink: link.url, at: link.range.location)
        guard clicked == link.url else { throw MailError(message: "Native link callback changed target") }
        linksButton.performClick(nil); await finishText()
        guard text.string == source, text.document?.links.isEmpty == true else { throw MailError(message: "Original links toggle failed") }
        linksButton.performClick(nil); await finishText()
        guard text.document?.links.count == 2 else { throw MailError(message: "Readable links toggle failed") }
        try WindowPresentation.snapshot(self, name: "reader-links")
        display(mail, mode: .html); try await finishHTML()
        try await snapshotHTML()
        let compactSource = "Shop logo] [Shop logo<https://example.test/shop>\nYour orders<https://example.test/orders> Offers<https://example.test/offers>\n\n\n[Shipment header]\n\nYour package was dispatched!\n[Completed]\nDispatched\n[Pending]\nDelivered\n\n- First item\n  - Nested detail\n\n> Earlier reply\n------"
        let compactMail = Mail(id: "compact-fixture", pinned: false, keepUnread: false, accountId: "demo", remoteId: "compact", sender: "Sample shop", senderAddress: "shop@example.test", recipient: "reader@example.test", subject: "Shipment example", preview: "Sample", timestamp: 0, unread: false, starred: false, hasAttachments: false, text: compactSource, html: "<img alt='Shipment header'><img alt='Shop logo'>")
        display(compactMail, mode: .text)
        if spacingButton.state != .on { spacingButton.performClick(nil) }
        await finishText()
        guard text.string.hasPrefix("Shop logo ↗\nYour orders ↗ Offers ↗\nShipment header"), text.string.contains("[Pending]"), text.string.contains("  - Nested detail\n> Earlier reply\n------"), compactMail.text == compactSource else { throw MailError(message: "Compact reader lost meaningful text or kept duplicate image labels") }
        try WindowPresentation.snapshot(self, name: "reader-compact-links")
        spacingButton.performClick(nil); await finishText()
        display(mail, mode: .text)
        showText(String(repeating: source + "\n", count: 1000)); showText("Latest selection")
        await finishText()
        guard text.string == "Latest selection" else { throw MailError(message: "Stale formatting replaced reader selection") }
    }

    private func snapshotHTML() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard WindowPresentation.isBackground, let index = args.firstIndex(of: "--mail-evidence-dir"), args.indices.contains(index + 1), let web else { return }
        let image: NSImage = try await withCheckedThrowingContinuation { reply in
            web.takeSnapshot(with: nil) { image, error in
                if let image { reply.resume(returning: image) }
                else { reply.resume(throwing: error ?? MailError(message: "HTML snapshot failed")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw MailError(message: "HTML snapshot encoding failed") }
        let path = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("reader-image-marker.png")
        try png.write(to: path)
    }

    func verifySpacing() async throws {
        let sample = "\n \nIntro\n\n\n- one\n  - nested\n\n> Reply\n> > Earlier\n------\n\n"
        let expected = "Intro\n- one\n  - nested\n> Reply\n> > Earlier\n------"
        guard CompactText.render(sample) == expected else { throw MailError(message: "Compact spacing damaged hierarchy or separators") }
        guard let original = message?.text, mode == .text else { throw MailError(message: "Spacing control needs a plain-text fixture") }
        spacingButton.performClick(nil); await finishText()
        guard text.string == CompactText.render(original), spacingButton.state == .on, message?.text == original else { throw MailError(message: "Compact spacing changed stored mail") }
        spacingButton.performClick(nil); await finishText()
        guard text.string == original, spacingButton.state == .off else { throw MailError(message: "Original spacing did not restore") }
    }
}
