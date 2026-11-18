import AppKit
import ClassicKit

@MainActor
final class NotificationPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let caption = NSTextField(labelWithString: "Recent notifications · at most 50, kept for 14 days")
    private let status = NSTextField(labelWithString: "")
    private let account = NSPopUpButton(frame: .zero)
    private let mail = NSButton(checkboxWithTitle: "New mail", target: nil, action: nil)
    private let calendar = NSButton(checkboxWithTitle: "Calendar reminders", target: nil, action: nil)
    private let desktop = ClassicButton("Enable macOS alerts")
    private let read = ClassicButton("Mark all read")
    private let clear = ClassicButton("Clear history")
    private var items: [AppNotice] = []
    private var settings: [NoticePreference] = []
    private let dateFormat = DateFormatter()
    var onAction: ((NoticeAction) -> Void)?
    var onOpen: ((AppNotice) -> Void)?
    var onDesktop: (() -> Void)?
    var onPreference: ((String?, NoticeChannel, NoticeToggle) -> Void)?

    override init() {
        super.init()
        window.title = "Square Mail notifications"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 350)
        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = ClassicTheme.face.cgColor
        caption.font = ClassicTheme.font(12, weight: .bold)
        caption.frame = NSRect(x: 12, y: 448, width: 616, height: 20)
        caption.autoresizingMask = [.width, .minYMargin]
        scroll.frame = NSRect(x: 10, y: 110, width: 620, height: 328)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notice"))
        column.width = 600
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Recent notifications")
        account.frame = NSRect(x: 10, y: 75, width: 285, height: 26)
        account.target = self; account.action = #selector(changeAccount)
        account.setAccessibilityLabel("Notification account")
        mail.frame = NSRect(x: 310, y: 76, width: 108, height: 25)
        calendar.frame = NSRect(x: 422, y: 76, width: 200, height: 25)
        mail.target = self; mail.action = #selector(changeMail)
        calendar.target = self; calendar.action = #selector(changeCalendar)
        desktop.frame = NSRect(x: 10, y: 40, width: 195, height: 28)
        read.frame = NSRect(x: 216, y: 40, width: 130, height: 28)
        clear.frame = NSRect(x: 355, y: 40, width: 130, height: 28)
        desktop.onPress = { [weak self] in self?.onDesktop?() }
        read.onPress = { [weak self] in self?.onAction?(.read) }
        clear.onPress = { [weak self] in self?.onAction?(.clear) }
        status.frame = NSRect(x: 12, y: 10, width: 616, height: 20)
        status.autoresizingMask = [.width]
        status.font = ClassicTheme.font(10)
        status.textColor = ClassicTheme.muted
        dateFormat.dateStyle = .short; dateFormat.timeStyle = .short
        for view in [caption, scroll, account, mail, calendar, desktop, read, clear, status] { content.addSubview(view) }
    }
    func open() { window.center(); window.makeKeyAndOrderFront(nil) }
    func close() { window.close() }
    func show(_ batch: NoticeBatch, accounts: [Account], desktop: NoticeDelivery, permission: NotificationPermission) {
        items = batch.items
        settings = batch.settings
        let selected = account.selectedItem?.representedObject as? String
        account.removeAllItems()
        account.addItem(withTitle: "All accounts")
        for value in accounts where value.provider != .local {
            account.addItem(withTitle: value.email)
            account.lastItem?.representedObject = value.id
            if value.id == selected { account.select(account.lastItem) }
        }
        changeAccount()
        self.desktop.title = desktop == .desktop ? "Disable macOS alerts" : "Enable macOS alerts"
        self.desktop.needsDisplay = true
        status.stringValue = desktop == .desktop ? "macOS alerts on · up to 32 upcoming reminders scheduled" : (permission == .allowed ? "macOS alerts off · history remains available" : "macOS permission is requested only when you enable alerts")
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoticeCell) ?? NoticeCell()
        cell.identifier = id
        let item = items[row]
        cell.show(item, date: dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(item.occurred))))
        return cell
    }
    @objc private func openSelected() {
        guard items.indices.contains(table.selectedRow) else { return }
        onOpen?(items[table.selectedRow])
    }
    @objc private func changeAccount() {
        let id = account.selectedItem?.representedObject as? String
        let selected = settings.filter { id == nil || $0.account == id }
        mail.state = selected.allSatisfy(\.mail) ? .on : (selected.allSatisfy { !$0.mail } ? .off : .mixed)
        calendar.state = selected.allSatisfy(\.calendar) ? .on : (selected.allSatisfy { !$0.calendar } ? .off : .mixed)
        mail.isEnabled = !selected.isEmpty; calendar.isEnabled = !selected.isEmpty
    }
    @objc private func changeMail() { onPreference?(account.selectedItem?.representedObject as? String, .mail, mail.state == .on ? .on : .off) }
    @objc private func changeCalendar() { onPreference?(account.selectedItem?.representedObject as? String, .calendar, calendar.state == .on ? .on : .off) }
}
private final class NoticeCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [title, subtitle] { field.lineBreakMode = .byTruncatingTail; addSubview(field) }
        subtitle.font = ClassicTheme.font(10); subtitle.textColor = ClassicTheme.muted
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func show(_ item: AppNotice, date: String) {
        let kind = item.kind == .mail ? "Mail" : (item.kind == .reminder ? "Reminder" : "Calendar")
        title.stringValue = (item.unread ? "● " : "") + kind + ": " + item.title
        title.font = ClassicTheme.font(12, weight: item.unread ? .bold : .regular)
        subtitle.stringValue = date + " · " + item.detail
        needsLayout = true
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 9, y: 32, width: max(0, bounds.width - 18), height: 20)
        subtitle.frame = NSRect(x: 9, y: 10, width: max(0, bounds.width - 18), height: 18)
    }
}
