import AppKit
import WebKit
import ClassicKit

enum HTMLPolicy {
    static let contentPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; media-src 'none'; font-src 'none'"

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
        a { color:#0a246a; } table { max-width:100%; } pre { white-space:pre-wrap; }
        hr { border:0; border-top:1px solid #d4d0c8; margin:18px 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func permitsLink(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }
}

final class ReaderView: NSView, WKNavigationDelegate {
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private var web: WKWebView?
    private var rendered = ""
    private var mode: ReaderMode = .text
    private var message: Mail?
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
        text.font = ClassicTheme.font(14)
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
        showNotice("Select a message to read it.")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        web?.frame = bounds
        text.setFrameSize(NSSize(width: bounds.width, height: max(bounds.height, text.frame.height)))
    }

    func display(_ mail: Mail, mode: ReaderMode) {
        message = mail
        self.mode = mode
        if mode == .text {
            web?.isHidden = true
            scroll.isHidden = false
            showText(mail.text ?? "This message is not cached. Sync and open it while online.")
            return
        }
        guard let html = mail.html, !html.isEmpty else {
            web?.isHidden = true
            scroll.isHidden = false
            showText(mail.text ?? "This message has no cached HTML body.")
            return
        }
        scroll.isHidden = true
        if let web { web.isHidden = false; load(html); return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: bounds, configuration: configuration)
        view.navigationDelegate = self
        addSubview(view)
        web = view
        // CSP and sanitization are active before the additional WebKit network rule arrives.
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "SquareMail.BlockResources.v1", encodedContentRuleList: rules) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self, let web = self.web, let list else { return }
                web.configuration.userContentController.add(list)
                if self.mode == .html, let html = self.message?.html { self.load(html) }
            }
        }
        load(html)
    }

    func showNotice(_ notice: String) {
        message = nil
        web?.isHidden = true
        scroll.isHidden = false
        showText(notice)
    }

    private func showText(_ value: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        text.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: [
            .font: ClassicTheme.font(14), .foregroundColor: ClassicTheme.ink,
            .paragraphStyle: paragraph
        ]))
        text.scrollToBeginningOfDocument(nil)
    }

    private func load(_ html: String) {
        guard rendered != html else { return }
        rendered = html
        web?.loadHTMLString(HTMLPolicy.document(html), baseURL: nil)
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
