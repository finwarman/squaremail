import AppKit
import ClassicKit

final class MailLayout: NSView, NSSplitViewDelegate {
    let titleBar = ClassicTitleBar()
    let menus = NSView()
    let toolbar = ClassicActionBar()
    let messageActions = ClassicActionBar()
    let sidebar = ClassicPanel()
    let filter = ClassicPanel()
    let split = NSSplitView()
    let listPane = ClassicPanel()
    let listCaption = NSTextField(labelWithString: "INBOX")
    let listScroll = NSScrollView()
    let readerPane = ClassicPanel()
    let header = MessageHeader()
    let reader = ReaderView()
    let status = ClassicPanel()
    let statusText = NSTextField(labelWithString: "Opening local mailbox…")
    let statusMode = NSTextField(labelWithString: "LOCAL DEMO")
    let statusReader = NSTextField(labelWithString: "PLAIN TEXT")
    let syncProgress = ClassicProgress()
    let searchBorder = ClassicPanel()
    let search = NSTextField()
    let folderLabel = NSTextField(labelWithString: "Inbox")
    private var scale: CGFloat = 1
    private let surface = ClassicSurface()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [titleBar, menus, toolbar, sidebar, filter, split, status] { addSubview(view) }
        sidebar.edge = .sunken
        filter.edge = .flat
        split.isVertical = false
        split.dividerStyle = .thick
        split.delegate = self
        split.addArrangedSubview(listPane)
        split.addArrangedSubview(readerPane)
        listPane.edge = .sunken
        listPane.fill = .white
        listPane.addSubview(listCaption)
        listCaption.font = ClassicTheme.font(11, weight: .bold)
        listCaption.textColor = ClassicTheme.muted
        listPane.addSubview(listScroll)
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        readerPane.edge = .sunken
        readerPane.fill = .white
        readerPane.addSubview(messageActions)
        readerPane.addSubview(header)
        readerPane.addSubview(reader)
        searchBorder.edge = .sunken
        searchBorder.fill = .white
        filter.addSubview(folderLabel)
        folderLabel.font = ClassicTheme.font(14, weight: .bold)
        filter.addSubview(searchBorder)
        searchBorder.addSubview(search)
        search.isBordered = false
        search.focusRingType = .none
        search.drawsBackground = false
        search.font = ClassicTheme.font(12)
        search.placeholderString = "Search this folder (⌘F)"
        search.setAccessibilityLabel("Search this folder")
        for field in [statusText, statusMode, statusReader] {
            field.font = ClassicTheme.font(11)
            field.textColor = ClassicTheme.muted
            status.addSubview(field)
        }
        status.addSubview(syncProgress)
        syncProgress.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        ClassicTheme.bevel(bounds)
    }

    override func updateLayer() {
        surface.update(layer, bounds: bounds, fill: ClassicTheme.face)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        titleBar.frame = NSRect(x: 3, y: 3, width: width - 6, height: 32)
        menus.frame = NSRect(x: 5, y: 36, width: width - 10, height: 25)
        toolbar.frame = NSRect(x: 4, y: 62, width: width - 8, height: toolbar.fittingHeight(width - 8))
        let contentTop = toolbar.frame.maxY + 4
        let left: CGFloat = 210
        sidebar.frame = NSRect(x: 4, y: contentTop, width: left - 8, height: height - contentTop - 28)
        filter.frame = NSRect(x: left, y: contentTop, width: width - left - 4, height: 40)
        folderLabel.frame = NSRect(x: 10, y: 9, width: 110, height: 22)
        searchBorder.frame = NSRect(x: max(245, filter.bounds.width - 365), y: 5, width: 355, height: 28)
        search.frame = searchBorder.bounds.insetBy(dx: 8, dy: 5)
        split.frame = NSRect(x: left, y: contentTop + 42, width: width - left - 4, height: max(0, height - contentTop - 70))
        layoutPanes()
        status.frame = NSRect(x: 4, y: height - 25, width: width - 8, height: 21)
        statusText.frame = NSRect(x: 8, y: 3, width: width - 500, height: 16)
        syncProgress.frame = NSRect(x: width - 485, y: 3, width: 130, height: 15)
        statusMode.frame = NSRect(x: width - 342, y: 3, width: 170, height: 16)
        statusReader.frame = NSRect(x: width - 164, y: 3, width: 148, height: 16)
        needsDisplay = true
    }

    func setReadingLayout(_ value: ReadingLayout) {
        split.isVertical = value == .right
        split.adjustSubviews()
        let length = split.isVertical ? split.bounds.width : split.bounds.height
        split.setPosition(floor(length * 0.4), ofDividerAt: 0)
        layoutPanes()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Divider dragging resizes child panes without laying out their parent.
        layoutPanes()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, splitView.isVertical ? 300 : 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.isVertical ? splitView.bounds.width - 340 : splitView.bounds.height - 280)
    }

    private func layoutPanes() {
        listCaption.frame = NSRect(x: 10, y: 7, width: max(0, listPane.bounds.width - 165), height: 17)
        listScroll.frame = NSRect(x: 2, y: 29, width: max(0, listPane.bounds.width - 4), height: max(0, listPane.bounds.height - 31))
        let width = max(0, readerPane.bounds.width - 4)
        let actionHeight = messageActions.fittingHeight(width)
        messageActions.frame = NSRect(x: 2, y: 2, width: width, height: actionHeight)
        let headerHeight: CGFloat = width < 600 ? 142 : 108
        header.frame = NSRect(x: 2, y: actionHeight + 2, width: width, height: headerHeight)
        let bodyTop = header.frame.maxY
        reader.frame = NSRect(x: 2, y: bodyTop, width: width, height: max(0, readerPane.bounds.height - bodyTop - 2))
    }
}

final class MessageHeader: NSView {
    private var message: Mail?
    private var date = ""
    private let dateFormat: DateFormatter = {
        let value = DateFormatter()
        value.dateStyle = .medium
        value.timeStyle = .short
        return value
    }()
    var mode: ReaderMode = .text { didSet { needsDisplay = true } }
    var images: ImagePermission = .blocked { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    func display(_ mail: Mail?) {
        message = mail
        date = mail.map { dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval($0.timestamp))) } ?? ""
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        ClassicTheme.shadow.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let message else {
            ClassicTheme.text("Reading pane", in: NSRect(x: 16, y: 15, width: 500, height: 24), size: 15, weight: .bold)
            return
        }
        ClassicTheme.text(message.subject, in: NSRect(x: 16, y: 12, width: bounds.width - 30, height: 25), size: 17, weight: .bold)
        ClassicTheme.text("From:", in: NSRect(x: 16, y: 45, width: 42, height: 18), size: 11, color: ClassicTheme.muted)
        let narrow = bounds.width < 600
        ClassicTheme.text("\(message.sender) <\(message.senderAddress)>", in: NSRect(x: 61, y: 43, width: bounds.width - (narrow ? 77 : 290), height: 20), size: 12)
        ClassicTheme.text("To:", in: NSRect(x: 16, y: 70, width: 42, height: 18), size: 11, color: ClassicTheme.muted)
        ClassicTheme.text(message.recipient, in: NSRect(x: 61, y: 68, width: bounds.width - (narrow ? 77 : 290), height: 20), size: 12)
        ClassicTheme.text(date, in: NSRect(x: narrow ? 16 : bounds.width - 255, y: narrow ? 96 : 44, width: narrow ? bounds.width - 32 : 236, height: 18), size: 11, color: ClassicTheme.muted, alignment: narrow ? .left : .right)
        ClassicTheme.text(mode == .text ? "PLAIN TEXT  ·  LOCAL CACHE" : (images == .loaded ? "HTML  ·  IMAGES LOADED" : "HTML  ·  REMOTE CONTENT BLOCKED"), in: NSRect(x: narrow ? 16 : bounds.width - 280, y: narrow ? 118 : 70, width: narrow ? bounds.width - 32 : 261, height: 18), size: 10, color: ClassicTheme.muted, alignment: narrow ? .left : .right)
    }
}
