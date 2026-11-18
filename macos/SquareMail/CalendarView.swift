import AppKit
import ClassicKit

enum CalendarFeed: String, CaseIterable {
    case google = "Google Calendar"
    case outlook = "Outlook.com / Live"
    case microsoft365 = "Microsoft 365"

    var color: NSColor {
        switch self {
        case .google: return ClassicTheme.color(0x2C68AD)
        case .outlook: return ClassicTheme.color(0x77589B)
        case .microsoft365: return ClassicTheme.color(0x367843)
        }
    }
}

struct CalendarState {
    var date = Date()
    var period: ClassicCalendarPeriod = .month
    var feeds = Set(CalendarFeed.allCases)
    var query = ""
    var hiddenSources: Set<String> = []
}

private struct SampleEvent {
    let key: EventKey?
    let mark: ClassicCalendarMark
    let feed: CalendarFeed?
    let sourceKey: String
    let sourceName: String
    let location: String
    let notes: String
}

private enum AgendaColumn: String {
    case time, title, calendar, location
}

final class CalendarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onNew: ((Date) -> Void)?
    var onEdit: ((EventKey) -> Void)?
    var onPending: (() -> Void)?
    var onDateChanged: ((Date) -> Void)?
    var range: (Date, Date) {
        let dates = grid.visibleDates
        return (dates.first!, Calendar.current.date(byAdding: .day, value: 1, to: dates.last!)!)
    }
    var state: CalendarState {
        CalendarState(date: grid.date, period: grid.period, feeds: feeds, query: query, hiddenSources: hiddenSources)
    }
    private let newEvent = ClassicButton("New event")
    private let editEvent = ClassicButton("Edit event")
    private let pending = ClassicButton("Drafts…")
    private let grid = ClassicCalendar()
    private let surface = ClassicSurface()
    private let caption = NSTextField(labelWithString: "")
    private let dayCaption = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "Select an event for details.")
    private let agenda = NSTableView()
    private let agendaScroll = NSScrollView()
    private let today = ClassicButton("Today")
    private let previous = ClassicButton("<")
    private let next = ClassicButton(">")
    private var modeButtons: [ClassicButton] = []
    private var feeds: Set<CalendarFeed>
    private var query: String
    private var events: [SampleEvent]
    private let mode: MailboxMode
    private var hiddenSources: Set<String>
    private var agendaItems: [SampleEvent] = []
    private let dateFormat = DateFormatter()
    private let timeFormat = DateFormatter()
    private let captionFormat = DateFormatter()
    private let storageDayFormat = DateFormatter()
    private static let rowID = NSUserInterfaceItemIdentifier("calendar-agenda-row")
    private static let minutesInDay = 24 * 60
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(state: CalendarState, mode: MailboxMode = .demo) {
        self.mode = mode
        hiddenSources = state.hiddenSources
        feeds = state.feeds
        query = state.query
        events = mode == .demo ? Self.makeEvents() : []
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        storageDayFormat.calendar = Calendar(identifier: .gregorian)
        storageDayFormat.locale = Locale(identifier: "en_US_POSIX")
        storageDayFormat.dateFormat = "yyyy-MM-dd"
        dateFormat.dateFormat = "EEEE d MMMM yyyy"
        timeFormat.dateFormat = "HH:mm"
        grid.date = state.date
        grid.period = state.period
        for view in [grid, caption, dayCaption, detail, agendaScroll, today, previous, next, newEvent, editEvent, pending] { addSubview(view) }
        caption.font = ClassicTheme.font(17, weight: .bold)
        dayCaption.font = ClassicTheme.font(12, weight: .bold)
        detail.font = ClassicTheme.font(11)
        detail.textColor = ClassicTheme.muted
        today.onPress = { [weak self] in self?.selectDate(Date()) }
        previous.onPress = { [weak self] in self?.step(-1) }
        next.onPress = { [weak self] in self?.step(1) }
        let names = ["Month", "Week", "Day"]
        for (index, period) in ClassicCalendarPeriod.allCases.enumerated() {
            let button = ClassicButton(names[index], style: .toggle)
            button.onPress = { [weak self] in self?.setPeriod(period) }
            addSubview(button)
            modeButtons.append(button)
        }
        grid.onSelectDate = { [weak self] date in self?.selectDate(date) }
        grid.onSelectItem = { [weak self] id in
            guard let self, let index = self.agendaItems.firstIndex(where: { $0.mark.id == id }) else { return }
            self.agenda.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        newEvent.onPress = { [weak self] in guard let self else { return }; onNew?(grid.date) }
        editEvent.onPress = { [weak self] in self?.editSelected() }
        pending.onPress = { [weak self] in self?.onPending?() }
        pending.toolTip = "Local calendar drafts and pending changes"
        newEvent.isEnabled = mode == .live; editEvent.isEnabled = false; pending.isEnabled = mode == .live
        buildAgenda()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(state:)") }

    override func updateLayer() { surface.update(layer, bounds: bounds, fill: ClassicTheme.face, edge: .sunken) }

    override func layout() {
        super.layout()
        previous.frame = NSRect(x: 10, y: 10, width: 28, height: 27)
        next.frame = NSRect(x: 42, y: 10, width: 28, height: 27)
        today.frame = NSRect(x: 80, y: 10, width: 64, height: 27)
        caption.frame = NSRect(x: 160, y: 12, width: bounds.width - 420, height: 27)
        for (index, button) in modeButtons.enumerated() {
            button.frame = NSRect(x: bounds.width - 220 + CGFloat(index) * 70, y: 10, width: 66, height: 27)
        }
        let agendaHeight: CGFloat = 175
        grid.frame = NSRect(x: 3, y: 47, width: bounds.width - 6, height: max(160, bounds.height - 47 - agendaHeight))
        dayCaption.frame = NSRect(x: 12, y: bounds.height - agendaHeight + 7, width: max(0, bounds.width - 345), height: 20)
        for (index, button) in [newEvent, editEvent, pending].enumerated() {
            button.frame = NSRect(x: bounds.width - 320 + CGFloat(index) * 105, y: bounds.height - agendaHeight + 2, width: 100, height: 27)
        }
        agendaScroll.frame = NSRect(x: 4, y: bounds.height - agendaHeight + 32, width: bounds.width - 8, height: 115)
        detail.frame = NSRect(x: 12, y: bounds.height - 23, width: bounds.width - 24, height: 18)
        needsDisplay = true
    }

    func selectDate(_ date: Date) {
        grid.date = date
        refresh()
        onDateChanged?(date)
    }

    func step(_ delta: Int) {
        let component: Calendar.Component = grid.period == .month ? .month : .day
        let amount = grid.period == .week ? delta * 7 : delta
        selectDate(Calendar.current.date(byAdding: component, value: amount, to: grid.date)!)
    }

    func setFeeds(_ feeds: Set<CalendarFeed>) { self.feeds = feeds; refresh() }
    func setQuery(_ query: String) { self.query = query; refresh() }

    func setHidden(_ sources: Set<String>) { hiddenSources = sources; refresh() }
    func setData(sources: [CalendarSource], events: [CalendarEvent]) {
        let byKey = Dictionary(sources.map { source in
            let hex = UInt32(source.color.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x2C68AD
            return (source.key, (name: source.name, color: ClassicTheme.color(hex)))
        }, uniquingKeysWith: { first, _ in first })
        self.events = events.compactMap { event in
            let key = event.sourceKey
            guard let source = byKey[key] else { return nil }
            let start = event.startDay.flatMap(storageDayFormat.date(from:)) ?? Date(timeIntervalSince1970: TimeInterval(event.start))
            let end = event.endDay.flatMap(storageDayFormat.date(from:)) ?? Date(timeIntervalSince1970: TimeInterval(event.end))
            let mark = ClassicCalendarMark(id: key + ":" + event.id, title: event.title, start: start, end: end,
                                           color: source.color, span: event.allDay ? .allDay : .timed)
            return SampleEvent(key: EventKey(account: event.accountId, calendar: event.calendarId, id: event.id), mark: mark, feed: nil, sourceKey: key, sourceName: source.name,
                               location: event.location, notes: source.name + (event.location.isEmpty ? "" : " · " + event.location))
        }
        refresh()
    }

    func snapshot() -> (CalendarView) -> Void {
        // Capture bounded event values, never the view tree being released.
        { [events] view in view.events = events; view.refresh() }
    }

    private func setPeriod(_ period: ClassicCalendarPeriod) { grid.period = period; refresh(); onDateChanged?(grid.date) }

    private func visibleEvents() -> [SampleEvent] {
        events.filter {
            (mode == .demo ? $0.feed.map(feeds.contains) ?? false : !hiddenSources.contains($0.sourceKey)) && (query.isEmpty || ($0.mark.title + " " + $0.location + " " + $0.notes).localizedCaseInsensitiveContains(query))
        }
    }

    private func refresh() {
        let visible = visibleEvents()
        grid.items = visible.map(\.mark)
        captionFormat.dateFormat = grid.period == .month ? "MMMM yyyy" : "d MMMM yyyy"
        caption.stringValue = captionFormat.string(from: grid.date)
        dayCaption.stringValue = dateFormat.string(from: grid.date) + (mode == .demo ? "  ·  SAMPLE EVENTS" : "  ·  CACHED EVENTS" + (events.count == 2000 ? " (2,000 shown)" : ""))
        for (index, button) in modeButtons.enumerated() {
            button.state = ClassicCalendarPeriod.allCases[index] == grid.period ? .on : .off
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: grid.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        agendaItems = visible.filter { $0.mark.start < end && $0.mark.end > start }.sorted { $0.mark.start < $1.mark.start }
        agenda.reloadData()
        detail.stringValue = agendaItems.isEmpty ? mode == .demo ? "No sample events on this day." : "No cached events on this day. Sync while online to download this month." : "Select an event for details."
    }

    private func buildAgenda() {
        let columns: [(AgendaColumn, String, Double)] = [(.time, "Time", 140), (.title, "Event", 470),
                                                       (.calendar, "Calendar", 210), (.location, "Location", 250)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.width = width
            column.headerCell = ClassicHeaderCell(textCell: title)
            agenda.addTableColumn(column)
        }
        agenda.style = .plain
        agenda.rowHeight = 25
        agenda.usesAutomaticRowHeights = false
        agenda.gridStyleMask = [.solidHorizontalGridLineMask]
        agenda.gridColor = ClassicTheme.color(0xE5E3DD)
        agenda.backgroundColor = .white
        agenda.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        agenda.dataSource = self
        agenda.delegate = self
        agenda.target = self; agenda.doubleAction = #selector(editSelected)
        agenda.setAccessibilityLabel("Events on selected day")
        agendaScroll.documentView = agenda
        agendaScroll.hasVerticalScroller = true
        agendaScroll.autohidesScrollers = true
        agendaScroll.borderType = .bezelBorder
    }

    func numberOfRows(in tableView: NSTableView) -> Int { agendaItems.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: Self.rowID, owner: self) as? ClassicRow) ?? ClassicRow()
        view.identifier = Self.rowID
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard agendaItems.indices.contains(row), let column = tableColumn else { return nil }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? ClassicTableCell) ?? ClassicTableCell()
        cell.identifier = column.identifier
        let event = agendaItems[row]
        switch AgendaColumn(rawValue: column.identifier.rawValue) {
        case .time: cell.configure(event.mark.span == .allDay ? "All day" : timeFormat.string(from: event.mark.start) + " - " + timeFormat.string(from: event.mark.end))
        case .title: cell.configure(event.mark.title, weight: .bold)
        case .calendar: cell.configure(event.sourceName)
        case .location, .none: cell.configure(event.location)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        editEvent.isEnabled = mode == .live && agendaItems.indices.contains(agenda.selectedRow)
        guard agendaItems.indices.contains(agenda.selectedRow) else { return }
        detail.stringValue = agendaItems[agenda.selectedRow].notes
    }

    @objc private func editSelected() {
        guard agendaItems.indices.contains(agenda.selectedRow), let key = agendaItems[agenda.selectedRow].key else { return }
        onEdit?(key)
    }

    func selfTest() throws {
        for (period, count) in [(ClassicCalendarPeriod.month, 42), (.week, 7), (.day, 1)] {
            setPeriod(period)
            guard grid.visibleDates.count == count else { throw MailError(message: "Calendar period has the wrong day count") }
        }
        setPeriod(.month)
        let date = grid.date
        step(1); step(-1)
        guard Calendar.current.isDate(date, equalTo: grid.date, toGranularity: .month) else { throw MailError(message: "Calendar navigation lost its month") }
        setQuery("design")
        guard !visibleEvents().isEmpty, visibleEvents().allSatisfy({ $0.mark.title.localizedCaseInsensitiveContains("design") }) else { throw MailError(message: "Calendar search did not filter sample events") }
        setQuery("")
        setFeeds([])
        guard grid.items.isEmpty else { throw MailError(message: "Hidden calendar sources still displayed events") }
        setFeeds(Set(CalendarFeed.allCases))
    }

    private static func makeEvents() -> [SampleEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let definitions: [(String, CalendarFeed, Int, Int, Int, String)] = [
            ("Design review", .microsoft365, 0, 10, 90, "Studio"),
            ("Project planning", .google, 0, 9, 60, "Meeting room"),
            ("Coffee with Alex", .outlook, 0, 14, 60, "Riverside café"),
            ("Morning run", .outlook, 1, 7, 60, "Park"),
            ("Product workshop", .microsoft365, 1, 11, 120, "Studio"),
            ("Calendar design", .google, 2, 10, 120, "Desk"),
            ("Lunch with friends", .outlook, 3, 12, 90, "Town"),
            ("Weekly review", .microsoft365, 3, 16, 60, "Meeting room"),
            ("Weekend walk", .outlook, 5, 10, 120, "Riverside"),
            ("Reading hour", .google, 6, 15, 60, "Library"),
            ("Demo milestone", .google, 7, 0, Self.minutesInDay, "All day"),
            ("Team catch-up", .microsoft365, -1, 10, 60, "Studio"),
            ("Travel planning", .outlook, 10, 18, 60, "Home")
        ]
        return definitions.enumerated().map { index, definition in
            let (title, feed, offset, hour, minutes, location) = definition
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            let end = minutes == Self.minutesInDay ? calendar.date(byAdding: .day, value: 1, to: start)!
                : calendar.date(byAdding: .minute, value: minutes, to: start)!
            let mark = ClassicCalendarMark(id: "sample-event-\(index)", title: title, start: start, end: end,
                                           color: feed.color, span: minutes == Self.minutesInDay ? .allDay : .timed)
            return SampleEvent(key: nil, mark: mark, feed: feed, sourceKey: feed.rawValue, sourceName: feed.rawValue, location: location,
                               notes: "Sample event from \(feed.rawValue). Live calendar connections and editing are not enabled.")
        }
    }
}

final class CalendarSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onDate: ((Date) -> Void)?
    var onFeeds: ((Set<CalendarFeed>) -> Void)?
    var onMail: (() -> Void)?
    var onHiddenSources: ((Set<String>) -> Void)?
    private let mode: MailboxMode
    private let sourceScroll = NSScrollView()
    private let sourceTable = NSTableView()
    private var sources: [(CalendarSource, String)] = []
    private var hiddenSources: Set<String> = []
    private let mini = ClassicCalendar(density: .compact)
    private let month = NSTextField(labelWithString: "")
    private let back = ClassicButton("Back to mail", icon: .mail)
    private let monthFormat = DateFormatter()
    private var checks: [NSButton] = []
    override var isFlipped: Bool { true }

    init(state: CalendarState, mode: MailboxMode = .demo) {
        self.mode = mode
        hiddenSources = state.hiddenSources
        super.init(frame: .zero)
        monthFormat.dateFormat = "MMMM yyyy"
        mini.date = state.date
        mini.onSelectDate = { [weak self] date in self?.showDate(date); self?.onDate?(date) }
        month.font = ClassicTheme.font(12, weight: .bold)
        addSubview(month); addSubview(mini); addSubview(back)
        back.onPress = { [weak self] in self?.onMail?() }
        for feed in CalendarFeed.allCases {
            let button = ClassicCheckbox(feed.rawValue)
            button.target = self
            button.action = #selector(changeFeeds)
            button.font = ClassicTheme.font(10)
            button.state = state.feeds.contains(feed) ? .on : .off
            addSubview(button)
            checks.append(button)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("calendar-source"))
        column.width = 180
        sourceTable.addTableColumn(column)
        sourceTable.headerView = nil
        sourceTable.rowHeight = 30
        sourceTable.dataSource = self
        sourceTable.delegate = self
        sourceTable.style = .plain
        sourceTable.setAccessibilityLabel("Calendar sources")
        sourceScroll.documentView = sourceTable
        sourceScroll.hasVerticalScroller = true
        sourceScroll.autohidesScrollers = true
        sourceScroll.isHidden = mode == .demo
        addSubview(sourceScroll)
        for check in checks { check.isHidden = mode == .live }
        showDate(state.date)
    }

    required init?(coder: NSCoder) { fatalError("Use init(state:)") }

    func showSources(_ sources: [CalendarSource], accounts: [Account], hidden: Set<String>) {
        guard mode == .live else { return }
        let emails = Dictionary(accounts.map { ($0.id, $0.email) }, uniquingKeysWith: { first, _ in first })
        self.sources = sources.map { ($0, $0.name + " · " + (emails[$0.accountId] ?? "")) }
        hiddenSources = hidden
        sourceTable.reloadData()
        needsDisplay = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sources.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CalendarSourceCell) ?? CalendarSourceCell()
        cell.identifier = id
        let (source, name) = sources[row]
        cell.configure(name, selected: hiddenSources.contains(source.key) ? .off : .on)
        cell.onChange = { [weak self] value in
            guard let self else { return }
            if value == .on { self.hiddenSources.remove(source.key) } else { self.hiddenSources.insert(source.key) }
            self.onHiddenSources?(self.hiddenSources)
        }
        return cell
    }

    func showDate(_ date: Date) {
        mini.date = date
        month.stringValue = monthFormat.string(from: date)
    }

    @objc private func changeFeeds() {
        let selected = Set(CalendarFeed.allCases.enumerated().filter { checks[$0.offset].state == .on }.map(\.element))
        onFeeds?(selected)
    }

    override func layout() {
        super.layout()
        month.frame = NSRect(x: 12, y: 44, width: bounds.width - 24, height: 22)
        mini.frame = NSRect(x: 10, y: 75, width: bounds.width - 20, height: 174)
        for (index, check) in checks.enumerated() { check.frame = NSRect(x: 12, y: 294 + index * 30, width: Int(bounds.width) - 20, height: 24) }
        sourceScroll.frame = NSRect(x: 8, y: 294, width: bounds.width - 16, height: max(20, bounds.height - 355))
        back.frame = NSRect(x: 10, y: bounds.height - 43, width: bounds.width - 20, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        NSGradient(starting: ClassicTheme.navy, ending: ClassicTheme.blue)?.draw(in: NSRect(x: 3, y: 3, width: bounds.width - 6, height: 29), angle: 0)
        ClassicTheme.text("Calendars", in: NSRect(x: 13, y: 9, width: 170, height: 20), color: .white, weight: .bold)
        ClassicTheme.text(mode == .demo ? "SAMPLE CALENDARS" : "CACHED CALENDARS", in: NSRect(x: 12, y: 269, width: 180, height: 17), size: 9, color: ClassicTheme.muted, weight: .bold)
        for (index, feed) in CalendarFeed.allCases.enumerated() where mode == .demo {
            feed.color.setFill()
            NSRect(x: bounds.width - 22, y: 301 + CGFloat(index) * 30, width: 8, height: 8).fill()
        }
        if mode == .demo {
            ClassicTheme.text("Demo data · not connected", in: NSRect(x: 12, y: 401, width: 180, height: 36), size: 10, color: ClassicTheme.muted)
        } else if sources.isEmpty {
            ClassicTheme.text("No cached calendars yet.", in: NSRect(x: 12, y: 303, width: 180, height: 36), size: 10, color: ClassicTheme.muted)
        }
    }
}

private final class CalendarSourceCell: NSView {
    private let check = ClassicCheckbox("")
    var onChange: ((NSControl.StateValue) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(check)
        check.target = self
        check.action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ title: String, selected: NSControl.StateValue) {
        check.title = title
        check.state = selected
        check.toolTip = title
        check.setAccessibilityLabel(title)
        check.needsDisplay = true
    }
    override func layout() { super.layout(); check.frame = bounds }
    @objc private func changed() { onChange?(check.state) }
}
