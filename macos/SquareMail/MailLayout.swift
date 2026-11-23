import AppKit
import ClassicKit

final class MailLayout: NSView, NSSplitViewDelegate {
    let titleBar = ClassicTitleBar()
    let menus = NSView()
    let toolbar = ClassicActionBar()
    let tabs = ClassicTabs()
    let notesHost = NSView()
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
    let statusReader = NSTextField(labelWithString: "Text")
    let syncProgress = ClassicProgress()
    let syncCaption = NSTextField(labelWithString: "Refresh checks connected mail and calendars")
    let searchBorder = ClassicPanel()
    let search = NSTextField()
    let clearSearch = ClassicButton("×")
    let searchScope = NSPopUpButton(frame: .zero)
    let fuzzy = ClassicButton("Fuzzy", style: .toggle)
    let folderLabel = NSTextField(labelWithString: "Inbox")
    var folderTitle: String {
        get { folderLabel.stringValue }
        set { folderLabel.stringValue = newValue; needsLayout = true }
    }
    private var composeButton: ClassicButton?
    private var scale: CGFloat = 1
    private let surface = ClassicSurface()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [titleBar, menus, toolbar, tabs, sidebar, filter, split, notesHost, status] { addSubview(view) }
        notesHost.isHidden = true
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
        searchBorder.addSubview(clearSearch)
        clearSearch.isHidden = true
        clearSearch.toolTip = "Clear search and restore this view. Search scope and Fuzzy stay unchanged."
        clearSearch.setAccessibilityLabel("Clear search")
        search.isBordered = false
        search.focusRingType = .none
        search.drawsBackground = false
        search.font = ClassicTheme.font(12)
        search.placeholderString = "Search this folder (⌘F)"
        search.setAccessibilityLabel("Search this folder")
        searchScope.addItems(withTitles: ["This folder", "All folders"])
        searchScope.font = ClassicTheme.font(11)
        searchScope.setAccessibilityLabel("Mail search scope")
        searchScope.toolTip = "All folders searches within the selected account or All accounts."
        fuzzy.toolTip = "When no literal/prefix matches exist, try bounded one-edit spelling corrections."
        filter.addSubview(searchScope); filter.addSubview(fuzzy)
        for field in [statusText, statusReader] {
            field.font = ClassicTheme.font(11)
            field.textColor = ClassicTheme.muted
            status.addSubview(field)
        }
        statusReader.alignment = .right
        status.addSubview(syncProgress)
        syncCaption.font = ClassicTheme.font(11); syncCaption.textColor = ClassicTheme.muted
        syncCaption.lineBreakMode = .byTruncatingTail; status.addSubview(syncCaption)
        syncProgress.setAccessibilityLabel("Mail and calendar sync")
        syncProgress.toolTip = "Sync is idle. Cached mail and calendars remain available."
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func setComposeButton(_ button: ClassicButton) {
        composeButton = button; filter.addSubview(button); needsLayout = true
    }

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
        tabs.frame = NSRect(x: 4, y: toolbar.frame.maxY + 4, width: width - 8, height: 30)
        let contentTop = tabs.frame.maxY + 3
        let statusTop = height - 46
        let left: CGFloat = 210
        notesHost.frame = NSRect(x: 4, y: contentTop, width: width - 8, height: max(0,statusTop - contentTop - 3))
        sidebar.frame = NSRect(x: 4, y: contentTop, width: left - 8, height: max(0, statusTop - contentTop - 3))
        filter.frame = NSRect(x: left, y: contentTop, width: width - left - 4, height: 40)
        searchBorder.frame = NSRect(x: max(245, filter.bounds.width - 365), y: 5, width: 355, height: 28)
        search.frame = NSRect(x: 8, y: 5, width: max(0, searchBorder.bounds.width - 38), height: max(0, searchBorder.bounds.height - 10))
        clearSearch.frame = NSRect(x: searchBorder.bounds.width - 26, y: 4, width: 20, height: 20)
        searchScope.frame = NSRect(x: searchBorder.frame.minX - 200, y: 7, width: 112, height: 26)
        fuzzy.frame = NSRect(x: searchBorder.frame.minX - 82, y: 7, width: 76, height: 26)
        let titleLimit = max(40, searchScope.frame.minX - 129)
        let titleWidth = min(titleLimit, min(180, ceil(folderLabel.intrinsicContentSize.width)))
        folderLabel.frame = NSRect(x: 10, y: 9, width: titleWidth, height: 22)
        composeButton?.frame = NSRect(x: folderLabel.frame.maxX + 12, y: 6, width: 95, height: 28)
        split.frame = NSRect(x: left, y: contentTop + 42, width: width - left - 4, height: max(0, statusTop - contentTop - 45))
        layoutPanes()
        status.frame = NSRect(x: 4, y: statusTop, width: width - 8, height: 42)
        statusText.frame = NSRect(x: 8, y: 3, width: width - 24, height: 16)
        syncProgress.frame = NSRect(x: 8, y: 24, width: 130, height: 14)
        syncCaption.frame = NSRect(x: 148, y: 23, width: max(0, width - 420), height: 16)
        statusReader.frame = NSRect(x: width - 256, y: 23, width: 240, height: 16)
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
    private var selectionCount = 0
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
        selectionCount = 0
        setAccessibilityLabel(mail?.displaySubject ?? "Reading pane")
        message = mail
        date = mail.map { dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval($0.timestamp))) } ?? ""
        needsDisplay = true
    }

    func displaySelection(_ count: Int) {
        display(nil); selectionCount = count
        setAccessibilityLabel("\(count) messages selected")
    }
    override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        ClassicTheme.shadow.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let message else {
            if selectionCount > 1 {
                ClassicTheme.text("\(selectionCount) messages selected", in: NSRect(x: 16, y: 15, width: bounds.width - 32, height: 25), size: 17, weight: .bold)
                ClassicTheme.text("Reply and Forward need one message.", in: NSRect(x: 16, y: 48, width: bounds.width - 32, height: 20), size: 12)
                ClassicTheme.text("Up to 100 messages per action · this page only", in: NSRect(x: 16, y: 75, width: bounds.width - 32, height: 20), size: 11, color: ClassicTheme.muted)
                return
            }
            ClassicTheme.text("Reading pane", in: NSRect(x: 16, y: 15, width: 500, height: 24), size: 15, weight: .bold)
            return
        }
        ClassicTheme.text(message.displaySubject, in: NSRect(x: 16, y: 12, width: bounds.width - 30, height: 25), size: 17, weight: .bold)
        ClassicTheme.text("From:", in: NSRect(x: 16, y: 45, width: 42, height: 18), size: 11, color: ClassicTheme.muted)
        let narrow = bounds.width < 600
        ClassicTheme.text(message.displayFrom, in: NSRect(x: 61, y: 43, width: bounds.width - (narrow ? 77 : 290), height: 20), size: 12)
        ClassicTheme.text("To:", in: NSRect(x: 16, y: 70, width: 42, height: 18), size: 11, color: ClassicTheme.muted)
        ClassicTheme.text(message.recipient, in: NSRect(x: 61, y: 68, width: bounds.width - (narrow ? 77 : 290), height: 20), size: 12)
        ClassicTheme.text(date, in: NSRect(x: narrow ? 16 : bounds.width - 255, y: narrow ? 96 : 44, width: narrow ? bounds.width - 32 : 236, height: 18), size: 11, color: ClassicTheme.muted, alignment: narrow ? .left : .right)
        ClassicTheme.text(mode == .text ? "PLAIN TEXT" : (images == .loaded ? "HTML  ·  IMAGES LOADED" : "HTML  ·  REMOTE CONTENT BLOCKED"), in: NSRect(x: narrow ? 16 : bounds.width - 280, y: narrow ? 118 : 70, width: narrow ? bounds.width - 32 : 261, height: 18), size: 10, color: ClassicTheme.muted, alignment: narrow ? .left : .right)
    }
}
