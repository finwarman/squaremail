import AppKit
import ClassicKit

extension CalendarSource {
    var tint: NSColor {
        let hex = UInt32(color.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x2C68AD
        return ClassicTheme.color(hex)
    }
}

final class CalendarSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum SourceRow { case domain(String), account(String), calendar(CalendarSource) }
    private static let collapseKey = "calendarCollapsedAccounts"
    var onDate: ((Date) -> Void)?
    var onFeeds: ((Set<CalendarFeed>) -> Void)?
    var onMail: (() -> Void)?
    var onHiddenSources: ((Set<String>) -> Void)?
    private let mode: MailboxMode
    private let sourceScroll = NSScrollView()
    private let sourceTable = CalendarSourceTable()
    private var sources: [CalendarSource] = []
    private var accounts: [String: Account] = [:]
    private var rows: [SourceRow] = []
    private var hiddenSources: Set<String> = []
    private var collapsed: Set<String> = []
    private let mini = ClassicCalendar(density: .compact)
    private let month = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let all = ClassicButton("All")
    private let none = ClassicButton("None")
    private let back = ClassicButton("Back to mail", icon: .mail)
    private let monthFormat = DateFormatter()
    private var checks: [NSButton] = []
    override var isFlipped: Bool { true }
    func redrawToday() { mini.needsDisplay = true }

    init(state: CalendarState, mode: MailboxMode = .demo) {
        self.mode = mode; hiddenSources = state.hiddenSources
        super.init(frame: .zero)
        if !WindowPresentation.isBackground { collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapseKey) ?? []) }
        monthFormat.dateFormat = "MMMM yyyy"; mini.date = state.date
        mini.onSelectDate = { [weak self] date in self?.showDate(date); self?.onDate?(date) }
        month.font = ClassicTheme.font(12, weight: .bold)
        count.font = ClassicTheme.font(10); count.textColor = ClassicTheme.ink
        all.toolTip = "Show all calendars, including collapsed accounts."
        none.toolTip = "Hide all calendars. This only changes this view."
        all.onPress = { [weak self] in self?.showAll() }
        none.onPress = { [weak self] in self?.hideAll() }
        back.onPress = { [weak self] in self?.onMail?() }
        for child in [month, mini, back, all, none, count] { addSubview(child) }
        for feed in CalendarFeed.allCases {
            let button = ClassicCheckbox(feed.rawValue)
            button.target = self; button.action = #selector(changeFeeds); button.font = ClassicTheme.font(10)
            button.state = state.feeds.contains(feed) ? .on : .off
            button.isHidden = mode == .live; addSubview(button); checks.append(button)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("calendar-source")); column.width = 180
        sourceTable.addTableColumn(column); sourceTable.headerView = nil; sourceTable.rowHeight = 28
        sourceTable.dataSource = self; sourceTable.delegate = self; sourceTable.style = .plain
        sourceTable.backgroundColor = ClassicTheme.face; sourceTable.setAccessibilityLabel("Calendars grouped by domain and account")
        sourceTable.onMenu = { [weak self] row in self?.menu(row) }
        sourceScroll.documentView = sourceTable; sourceScroll.hasVerticalScroller = true; sourceScroll.autohidesScrollers = true
        sourceScroll.isHidden = mode == .demo; addSubview(sourceScroll)
        for control in [all, none, count] { control.isHidden = mode == .demo }
        showDate(state.date); updateCount()
    }
    required init?(coder: NSCoder) { fatalError("Use init(state:)") }

    func showSources(_ sources: [CalendarSource], accounts: [Account], hidden: Set<String>) {
        guard mode == .live else { return }
        self.sources = sources; self.accounts = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hiddenSources = hidden; rebuild(); needsDisplay = true
    }
    private func email(_ account: String) -> String { accounts[account]?.email ?? "Unknown account" }
    private func domain(_ account: String) -> String {
        let parts = email(account).split(separator: "@")
        return parts.count == 2 ? String(parts[1]).lowercased() : "Other accounts"
    }
    private func rebuild() {
        let groups = Dictionary(grouping: sources, by: \.accountId)
        let ids = groups.keys.sorted { (domain($0), email($0), $0) < (domain($1), email($1), $1) }
        rows.removeAll(keepingCapacity: true)
        var previous: String?
        for id in ids {
            let domain = domain(id)
            if domain != previous { rows.append(.domain(domain)); previous = domain }
            rows.append(.account(id))
            guard !collapsed.contains(id) else { continue }
            for source in (groups[id] ?? []).sorted(by: { a, b in a.isPrimary != b.isPrimary ? a.isPrimary : (a.name, a.id) < (b.name, b.id) }) { rows.append(.calendar(source)) }
        }
        sourceTable.reloadData(); updateCount(); sourceScroll.isHidden = mode == .demo || sources.isEmpty
    }
    private func updateCount() {
        let shown = sources.filter { !hiddenSources.contains($0.key) }.count
        count.stringValue = "\(shown) of \(sources.count) shown"
        all.isEnabled = shown < sources.count; none.isEnabled = shown > 0
    }
    private func changed() { sourceTable.reloadData(); updateCount(); onHiddenSources?(hiddenSources) }
    @objc private func showAll() { hiddenSources.removeAll(); changed() }
    private func hideAll() { hiddenSources.formUnion(sources.map(\.key)); changed() }
    private func showOnly(_ key: String) {
        guard sources.contains(where: { $0.key == key }) else { return }
        hiddenSources.formUnion(sources.map(\.key)); hiddenSources.remove(key); changed()
    }
    private func showAccount(_ id: String) { for source in sources where source.accountId == id { hiddenSources.remove(source.key) }; changed() }
    private func hideAccount(_ id: String) { hiddenSources.formUnion(sources.filter { $0.accountId == id }.map(\.key)); changed() }
    private func toggleAccount(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        if !WindowPresentation.isBackground { UserDefaults.standard.set(collapsed.sorted(), forKey: Self.collapseKey) }
        rebuild()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 28 }
        if case .domain = rows[row] { return 22 }; return 28
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .domain(let value):
            let id = NSUserInterfaceItemIdentifier("calendar-domain")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell ?? ClassicTableCell(); cell.identifier = id
            cell.configure(value.uppercased()); cell.toolTip = value; return cell
        case .account(let id):
            let identifier = NSUserInterfaceItemIdentifier("calendar-account")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CalendarAccountCell ?? CalendarAccountCell(); cell.identifier = identifier
            cell.configure(email(id), expanded: collapsed.contains(id) ? .off : .on)
            cell.onToggle = { [weak self] in self?.toggleAccount(id) }
            cell.onMore = { [weak self, weak cell] in self?.popup(row, in: cell) }; return cell
        case .calendar(let source):
            let id = NSUserInterfaceItemIdentifier("calendar-row")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? CalendarSourceCell ?? CalendarSourceCell(); cell.identifier = id
            cell.configure(source, selected: hiddenSources.contains(source.key) ? .off : .on, account: email(source.accountId))
            cell.onChange = { [weak self] value in
                guard let self else { return }
                if value == .on { hiddenSources.remove(source.key) } else { hiddenSources.insert(source.key) }; changed()
            }
            cell.onMore = { [weak self, weak cell] in self?.popup(row, in: cell) }; return cell
        }
    }
    private func popup(_ row: Int, in view: NSView?) {
        guard let view, !WindowPresentation.isBackground else { return }
        menu(row)?.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 24, y: view.bounds.height), in: view)
    }
    private func menu(_ row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = key
        }
        switch rows[row] {
        case .domain: return nil
        case .account(let id):
            add("Show calendars in this account", #selector(showAccountItem), id)
            add("Hide calendars in this account", #selector(hideAccountItem), id)
        case .calendar(let source):
            add("Show only this calendar", #selector(showOnlyItem), source.key)
            add("Show calendars in this account", #selector(showAccountItem), source.accountId)
            add("Hide calendars in this account", #selector(hideAccountItem), source.accountId)
        }
        menu.addItem(.separator()); add("Show all calendars", #selector(showAll), "")
        return menu
    }
    @objc private func showOnlyItem(_ item: NSMenuItem) { if let key = item.representedObject as? String { showOnly(key) } }
    @objc private func showAccountItem(_ item: NSMenuItem) { if let id = item.representedObject as? String { showAccount(id) } }
    @objc private func hideAccountItem(_ item: NSMenuItem) { if let id = item.representedObject as? String { hideAccount(id) } }
    func showDate(_ date: Date) { mini.date = date; month.stringValue = monthFormat.string(from: date) }
    @objc private func changeFeeds() { onFeeds?(Set(CalendarFeed.allCases.enumerated().filter { checks[$0.offset].state == .on }.map(\.element))) }
    override func layout() {
        super.layout()
        month.frame = NSRect(x: 12, y: 44, width: bounds.width - 24, height: 22)
        mini.frame = NSRect(x: 10, y: 75, width: bounds.width - 20, height: 174)
        all.frame = NSRect(x: bounds.width - 98, y: 263, width: 42, height: 24)
        none.frame = NSRect(x: bounds.width - 52, y: 263, width: 44, height: 24)
        for (index, check) in checks.enumerated() { check.frame = NSRect(x: 12, y: 294 + index * 30, width: Int(bounds.width) - 20, height: 24) }
        sourceScroll.frame = NSRect(x: 8, y: 294, width: bounds.width - 16, height: max(20, bounds.height - 380))
        count.frame = NSRect(x: 12, y: bounds.height - 75, width: bounds.width - 24, height: 22)
        back.frame = NSRect(x: 10, y: bounds.height - 43, width: bounds.width - 20, height: 28)
        sourceTable.sizeLastColumnToFit()
    }
    override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        NSGradient(starting: ClassicTheme.navy, ending: ClassicTheme.blue)?.draw(in: NSRect(x: 3, y: 3, width: bounds.width - 6, height: 29), angle: 0)
        ClassicTheme.text("Calendars", in: NSRect(x: 13, y: 9, width: 170, height: 20), color: .white, weight: .bold)
        ClassicTheme.text(mode == .demo ? "SAMPLE CALENDARS" : "SHOW", in: NSRect(x: 12, y: 269, width: 100, height: 17), size: 9, color: ClassicTheme.ink, weight: .bold)
        for (index, feed) in CalendarFeed.allCases.enumerated() where mode == .demo { feed.color.setFill(); NSRect(x: bounds.width - 22, y: 301 + CGFloat(index) * 30, width: 8, height: 8).fill() }
        if mode == .demo { ClassicTheme.text("Demo data · not connected", in: NSRect(x: 12, y: 401, width: 180, height: 36), size: 10, color: ClassicTheme.muted) }
        else if sources.isEmpty { ClassicTheme.text("No calendars to show yet. Refresh or connect an account.", in: NSRect(x: 12, y: 303, width: bounds.width - 24, height: 55), size: 10, color: ClassicTheme.ink) }
    }
}

private final class CalendarSourceTable: NSTableView {
    var onMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(row(at: convert(event.locationInWindow, from: nil))) }
}
private final class CalendarAccountCell: NSView {
    private let toggle = ClassicButton("", style: .menu)
    private let label = NSTextField(labelWithString: "")
    private let more = ClassicButton("⋯", style: .menu)
    var onToggle: (() -> Void)?
    var onMore: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(toggle); addSubview(label); addSubview(more)
        label.font = ClassicTheme.font(10, weight: .bold); label.textColor = ClassicTheme.ink; label.lineBreakMode = .byTruncatingTail
        toggle.onPress = { [weak self] in self?.onToggle?() }; more.onPress = { [weak self] in self?.onMore?() }
        more.toolTip = "Show or hide calendars in this account."
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ email: String, expanded: NSControl.StateValue) {
        toggle.title = expanded == .on ? "▾" : "▸"; toggle.toolTip = email
        label.stringValue = email; label.toolTip = email
        toggle.setAccessibilityLabel((expanded == .on ? "Collapse " : "Expand ") + email)
        more.setAccessibilityLabel("Calendar options for " + email)
    }
    override func layout() { super.layout(); toggle.frame = NSRect(x: 2, y: 2, width: 20, height: bounds.height - 4); label.frame = NSRect(x: 24, y: floor((bounds.height - 16) / 2), width: max(0, bounds.width - 52), height: 17); more.frame = NSRect(x: bounds.width - 26, y: 2, width: 24, height: bounds.height - 4) }
}
private final class CalendarSourceCell: NSView {
    private let check = ClassicCheckbox("")
    private let more = ClassicButton("⋯", style: .menu)
    private var tint = NSColor.blue
    var onChange: ((NSControl.StateValue) -> Void)?
    var onMore: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(check); addSubview(more)
        check.target = self; check.action = #selector(changed)
        more.onPress = { [weak self] in self?.onMore?() }; more.toolTip = "Show only this calendar or change account visibility."
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ source: CalendarSource, selected: NSControl.StateValue, account: String) {
        check.title = source.name; check.state = selected; check.toolTip = source.name + " · " + account
        check.setAccessibilityLabel(source.name + ", " + account); more.setAccessibilityLabel("Options for " + source.name)
        tint = source.tint; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        tint.setFill(); NSRect(x: 5, y: bounds.midY - 5, width: 10, height: 10).fill()
        ClassicTheme.shadow.setStroke(); NSBezierPath(rect: NSRect(x: 5.5, y: bounds.midY - 4.5, width: 9, height: 9)).stroke()
    }
    override func layout() { super.layout(); check.frame = NSRect(x: 20, y: 0, width: max(0, bounds.width - 46), height: bounds.height); more.frame = NSRect(x: bounds.width - 24, y: 2, width: 22, height: bounds.height - 4) }
    @objc private func changed() { onChange?(check.state) }
}

extension CalendarSidebar {
    func verifySources() throws {
        guard WindowPresentation.isBackground else { throw MailError(message: "Use hidden calendar visibility fixtures") }
        let saved = (sources, Array(accounts.values), hiddenSources)
        defer { showSources(saved.0, accounts: saved.1, hidden: saved.2); onHiddenSources?(saved.2) }
        let fixtureAccounts = [Account(id: "personal", email: "me@gmail.test", provider: .gmail, connected: false), Account(id: "work", email: "me@company.test", provider: .outlook, connected: false)]
        let fixtureSources = [CalendarSource(accountId: "personal", id: "primary", name: "Personal", color: "#3366CC", isPrimary: true), CalendarSource(accountId: "personal", id: "family", name: "Family", color: "#25845A", isPrimary: false), CalendarSource(accountId: "work", id: "primary", name: "Work", color: "#B75C17", isPrimary: true)]
        showSources(fixtureSources, accounts: fixtureAccounts, hidden: [])
        guard rows.count == 7 else { throw MailError(message: "Calendar groups lost domain, account or calendar rows") }
        showOnly(fixtureSources[1].key)
        guard !hiddenSources.contains(fixtureSources[1].key), hiddenSources.contains(fixtureSources[0].key), hiddenSources.contains(fixtureSources[2].key), count.stringValue == "1 of 3 shown" else { throw MailError(message: "Show only crossed calendar identity or missed hidden rows") }
        showAccount("personal")
        guard hiddenSources == [fixtureSources[2].key] else { throw MailError(message: "Account visibility changed another account") }
        let hidden = hiddenSources; toggleAccount("personal")
        guard rows.count == 5, hiddenSources == hidden else { throw MailError(message: "Collapsing a calendar account changed event visibility") }
        toggleAccount("personal"); showAll()
        guard hiddenSources.isEmpty, !all.isEnabled, none.isEnabled else { throw MailError(message: "Show all retained hidden calendars") }
        hideAll(); guard hiddenSources.count == 3, !none.isEnabled, all.isEnabled else { throw MailError(message: "Hide all left calendars active") }
        showAll(); layoutSubtreeIfNeeded(); try WindowPresentation.snapshot(self, name: "calendar-groups")
        guard let row = rows.firstIndex(where: { if case .calendar = $0 { return true }; return false }), let item = menu(row)?.items.first, item.title == "Show only this calendar", let action = item.action else { throw MailError(message: "Calendar options lack a solo action") }
        guard NSApp.sendAction(action, to: item.target, from: item), hiddenSources.count == 2 else { throw MailError(message: "Calendar solo menu did not change visibility") }
    }
}
