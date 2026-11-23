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

enum AgendaLayout: String { case below, right }

struct CalendarState {
    var date = Date()
    var period: ClassicCalendarPeriod = .month
    var feeds = Set(CalendarFeed.allCases)
    var query = ""
    var hiddenSources: Set<String> = []
    var agendaLayout: AgendaLayout = .below
    var belowRatio: Double = 0.7
    var rightRatio: Double = 0.6
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
    case time, title, calendar, location, summary
}

final class CalendarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    var onNew: ((Date) -> Void)?
    var onEdit: ((EventKey) -> Void)?
    var onPending: (() -> Void)?
    var onDailyNote: ((Date) -> Void)?
    var onDateChanged: ((Date) -> Void)?
    var onLayoutChange: ((CalendarState) -> Void)?
    var range: (Date, Date) {
        let dates = grid.visibleDates
        return (dates.first!, Calendar.current.date(byAdding: .day, value: 1, to: dates.last!)!)
    }
    var state: CalendarState {
        CalendarState(date: grid.date, period: grid.period, feeds: feeds, query: query, hiddenSources: hiddenSources, agendaLayout: agendaLayout, belowRatio: belowRatio, rightRatio: rightRatio)
    }
    private let newEvent = ClassicButton("New event")
    private let editEvent = ClassicButton("Edit event")
    private let pending = ClassicButton("Drafts…")
    private let dailyNote = ClassicButton("Daily note")
    private let grid = ClassicCalendar()
    private let split = AgendaSplit()
    private let gridPane = ClassicPanel()
    private let agendaPane = ClassicPanel()
    private let agendaActions = ClassicActionBar()
    private var agendaLayout: AgendaLayout
    private var belowRatio: Double
    private var rightRatio: Double
    private var layingOut = false
    private let surface = ClassicSurface()
    private let caption = NSTextField(labelWithString: "")
    private let dayCaption = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "Select an event for details.")
    private let agenda = NSTableView()
    private let agendaHeader = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
    private let agendaScroll = NSScrollView()
    var onClockTick: (() -> Void)?
    enum ClockActivity { case running, stopped }
    private var clockTask: Task<Void, Never>?
    private let clock = NSTextField(labelWithString: "")
    private let clockFormat: DateFormatter = { let value = DateFormatter(); value.dateFormat = "EEE d MMM yyyy · HH:mm z"; return value }()
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
    private var nowRow: Int?
    private var agendaNow = Date()
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
        agendaLayout = state.agendaLayout
        belowRatio = Self.safeRatio(state.belowRatio, fallback: 0.7)
        rightRatio = Self.safeRatio(state.rightRatio, fallback: 0.6)
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
        for view in [split, caption, detail, today, previous, next, clock] { addSubview(view) }
        split.isVertical = agendaLayout == .right; split.dividerStyle = .thick; split.delegate = self
        split.setAccessibilityLabel("Calendar grid and selected-day agenda")
        split.addArrangedSubview(gridPane); split.addArrangedSubview(agendaPane)
        gridPane.edge = .flat; agendaPane.edge = .flat
        gridPane.addSubview(grid)
        for view in [dayCaption, agendaScroll, agendaActions] { agendaPane.addSubview(view) }
        split.onDragEnd = { [weak self] in guard let self else { return }; onLayoutChange?(self.state) }
        for button in [newEvent, editEvent, pending] { agendaActions.addItem(button, width: 98) }
        clock.font = ClassicTheme.font(10); clock.textColor = ClassicTheme.muted; clock.alignment = .right
        tickClock()
        caption.font = ClassicTheme.font(17, weight: .bold)
        dayCaption.font = ClassicTheme.font(12, weight: .bold)
        dayCaption.lineBreakMode = .byTruncatingTail
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
            self.agenda.selectRowIndexes(IndexSet(integer: self.agendaRow(index)), byExtendingSelection: false)
        }
        newEvent.onPress = { [weak self] in guard let self else { return }; onNew?(grid.date) }
        editEvent.onPress = { [weak self] in self?.editSelected() }
        pending.onPress = { [weak self] in self?.onPending?() }
        dailyNote.onPress = { [weak self] in guard let self else { return }; onDailyNote?(grid.date) }
        dailyNote.toolTip = "Open the local Markdown note for the selected date."
        agendaActions.addItem(dailyNote, width: 100, priority: .secondary)
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
        layingOut = true
        split.frame = NSRect(x: 3, y: 47, width: max(0, bounds.width - 6), height: max(0, bounds.height - 73))
        let ratio = agendaLayout == .right ? rightRatio : belowRatio
        let limits = splitLimits()
        split.setPosition(min(limits.max, max(limits.min, floor(splitLength * ratio))), ofDividerAt: 0)
        layoutAgenda()
        layingOut = false
        detail.frame = NSRect(x: 12, y: bounds.height - 23, width: max(0, bounds.width - 305), height: 18)
        clock.frame = NSRect(x: bounds.width - 285, y: bounds.height - 23, width: 273, height: 18)
        needsDisplay = true
    }

    private static func safeRatio(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(0.85, max(0.15, value)) : fallback
    }
    private var splitLength: CGFloat { max(0, (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness) }
    private func splitLimits() -> (min: CGFloat, max: CGFloat) {
        let first: CGFloat = split.isVertical ? 360 : 210
        let second: CGFloat = split.isVertical ? 280 : 160
        let scale = min(1, splitLength / (first + second))
        return (first * scale, splitLength - second * scale)
    }
    private func layoutAgenda() {
        grid.frame = gridPane.bounds
        let width = agendaPane.bounds.width
        let stacked = width < 760
        let actionsWidth = stacked ? width : 324
        let actionsHeight = agendaActions.fittingHeight(actionsWidth)
        dayCaption.frame = NSRect(x: 9, y: 7, width: max(0, width - (stacked ? 18 : actionsWidth + 12)), height: 20)
        agendaActions.frame = NSRect(x: stacked ? 0 : width - actionsWidth, y: stacked ? 27 : 0, width: actionsWidth, height: actionsHeight)
        let top = agendaActions.frame.maxY
        agendaScroll.frame = NSRect(x: 2, y: top, width: max(0, width - 4), height: max(0, agendaPane.bounds.height - top - 2))
        if agendaLayout == .right, let column = agenda.tableColumns.first { column.width = max(0, agendaScroll.contentSize.width) }
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        layoutAgenda()
        guard !layingOut, splitLength > 0 else { return }
        let length = split.isVertical ? gridPane.frame.width : gridPane.frame.height
        let ratio = Self.safeRatio(length / splitLength, fallback: 0.6)
        if agendaLayout == .right { rightRatio = ratio } else { belowRatio = ratio }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(proposedMinimumPosition, splitLimits().min) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(proposedMaximumPosition, splitLimits().max) }

    func setAgendaLayout(_ value: AgendaLayout) {
        guard value != agendaLayout else { return }
        let selected = selectedEvent?.mark.id
        layingOut = true
        agendaLayout = value; split.isVertical = value == .right
        configureAgenda()
        layingOut = false
        needsLayout = true; layoutSubtreeIfNeeded()
        if let index = agendaItems.firstIndex(where: { $0.mark.id == selected }) {
            agenda.selectRowIndexes(IndexSet(integer: agendaRow(index)), byExtendingSelection: false)
            agenda.scrollRowToVisible(agendaRow(index))
        }
        onLayoutChange?(state)
    }

    func setClock(_ activity: ClockActivity) {
        clockTask?.cancel(); clockTask = nil
        guard activity == .running else { return }
        tickClock()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.tickClock()
            }
        }
    }
    func verifyClock() throws {
        let selected = grid.date
        setClock(.running); let old = clockTask; setClock(.running)
        guard old?.isCancelled == true, clockTask != nil, !clock.stringValue.isEmpty, grid.date == selected else { throw MailError(message: "Calendar clock duplicated work or changed the selected day") }
        setPeriod(.week); try WindowPresentation.snapshot(self, name: "calendar-week")
        setPeriod(.month); try WindowPresentation.snapshot(self, name: "calendar-month")
        try verifyAgendaLayout()
        try verifyAgendaClock()
    }
    func verifyAgendaLayout() throws {
        guard WindowPresentation.isBackground else { throw MailError(message: "Use a hidden generated calendar") }
        let saved = state; let frame = self.frame
        let marks = grid.items.map(\.id); let selectedDate = grid.date
        if !agendaItems.isEmpty { agenda.selectRowIndexes(IndexSet(integer: agendaRow(0)), byExtendingSelection: false) }
        let selected = agendaItems.first?.mark.id
        defer {
            belowRatio = saved.belowRatio; rightRatio = saved.rightRatio
            setAgendaLayout(saved.agendaLayout); self.frame = frame
            needsLayout = true; layoutSubtreeIfNeeded()
        }
        let changed = onDateChanged; var dateCallbacks = 0
        onDateChanged = { _ in dateCallbacks += 1 }
        defer { onDateChanged = changed }
        for orientation in [AgendaLayout.right, .below, .right] {
            setAgendaLayout(orientation)
            for size in [NSSize(width: 640, height: 480), NSSize(width: 1100, height: 720)] {
                setFrameSize(size); needsLayout = true; layoutSubtreeIfNeeded()
                let limits = splitLimits()
                for position in [limits.min, (limits.min + limits.max) / 2, limits.max] {
                    split.setPosition(position, ofDividerAt: 0); layoutSubtreeIfNeeded()
                    guard grid.frame == gridPane.bounds, agendaPane.bounds.contains(agendaScroll.frame),
                          abs(agendaScroll.frame.maxY - (agendaPane.bounds.height - 2)) < 1,
                          !dayCaption.frame.intersects(agendaActions.frame) else { throw MailError(message: "Agenda divider left stale or overlapping content") }
                    guard grid.date == selectedDate, grid.items.map(\.id) == marks, dateCallbacks == 0 else { throw MailError(message: "Agenda layout reloaded events or changed date") }
                    if let selected {
                        guard selectedEvent?.mark.id == selected else { throw MailError(message: "Agenda layout lost the selected event") }
                    }
                    if orientation == .right {
                        guard agenda.tableColumns.count == 1, agenda.rowHeight == 65 else { throw MailError(message: "Right agenda lost its compact rows") }
                        if !agendaItems.isEmpty, let cell = agenda.view(atColumn: 0, row: agendaRow(0), makeIfNecessary: true) {
                            guard cell is AgendaSummaryCell else { throw MailError(message: "Right agenda has no reusable summary cell") }
                        }
                    }
                }
            }
            let limits = splitLimits()
            split.setPosition((limits.min + limits.max) / 2, ofDividerAt: 0)
            layoutSubtreeIfNeeded()
            try WindowPresentation.snapshot(self, name: "agenda-" + orientation.rawValue)
        }
    }
    private func verifyAgendaClock() throws {
        guard WindowPresentation.isBackground else { throw MailError(message: "Use a hidden calendar fixture") }
        let saved = state; let items = agendaItems
        defer { grid.date = saved.date; agendaItems = items; setAgendaLayout(saved.agendaLayout); updateAgendaClock(Date()) }
        grid.date = Date(); setAgendaLayout(.right)
        let day = Calendar.current.startOfDay(for: grid.date)
        let start = day.addingTimeInterval(12 * 3600)
        let mark = ClassicCalendarMark(id: "clock-fixture", title: "Ongoing event", start: start, end: start.addingTimeInterval(3600), color: .blue, span: .timed)
        agendaItems = [SampleEvent(key: nil, mark: mark, feed: nil, sourceKey: "clock", sourceName: "Fixture", location: "", notes: "")]
        updateAgendaClock(start.addingTimeInterval(1800))
        guard nowRow == 1, numberOfRows(in: agenda) == 2, eventProgress(agendaItems[0]) == 0.5,
              !tableView(agenda, shouldSelectRow: 1) else { throw MailError(message: "Agenda clock lost time or event progress") }
        agenda.selectRowIndexes(IndexSet(integer: agendaRow(0)), byExtendingSelection: false)
        updateAgendaClock(start.addingTimeInterval(3600))
        guard nowRow == 1, selectedEvent?.mark.id == mark.id, eventProgress(agendaItems[0]) == nil else { throw MailError(message: "Agenda clock rollover lost selection") }
        updateAgendaClock(start.addingTimeInterval(1800))
        needsLayout = true; layoutSubtreeIfNeeded()
        try WindowPresentation.snapshot(self, name: "agenda-now")
        setAgendaLayout(.below)
        guard nowRow == nil, selectedEvent?.mark.id == mark.id else { throw MailError(message: "Agenda layout retained an invalid clock row") }
        setAgendaLayout(.right); grid.date = day.addingTimeInterval(-86400); updateAgendaClock(start)
        guard nowRow == nil else { throw MailError(message: "Agenda clock appeared on a different day") }
        grid.date = day; refresh(); setAgendaLayout(.right)
        let long = ClassicCalendarMark(id: "long", title: "Overnight on-call", start: day.addingTimeInterval(-15 * 3600), end: day.addingTimeInterval(33 * 3600), color: .blue, span: .timed)
        let past = ClassicCalendarMark(id: "past", title: "Earlier short event", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10 * 3600), color: .blue, span: .timed)
        let future = ClassicCalendarMark(id: "future", title: "Later event", start: day.addingTimeInterval(14 * 3600), end: day.addingTimeInterval(15 * 3600), color: .blue, span: .timed)
        agendaItems = [long, past, mark, future].map { SampleEvent(key: nil, mark: $0, feed: nil, sourceKey: "clock", sourceName: "Fixture", location: "", notes: "") }
        updateAgendaClock(start.addingTimeInterval(1800))
        guard nowRow == 3, eventProgress(agendaItems[0]) != nil, eventProgress(agendaItems[1]) == nil, eventProgress(agendaItems[2]) == 0.5,
              agendaTime(long) != timeFormat.string(from: long.start) + " - " + timeFormat.string(from: long.end) else { throw MailError(message: "Agenda Now split past starts or hid overlapping progress") }
        try WindowPresentation.snapshot(self, name: "agenda-overlap-now")
    }
    private func tickClock() {
        let now = Date()
        clock.stringValue = clockFormat.string(from: now)
        updateAgendaClock(now)
        grid.needsDisplay = true; onClockTick?()
    }
    private var selectedEvent: SampleEvent? {
        eventIndex(agenda.selectedRow).map { agendaItems[$0] }
    }
    private func eventIndex(_ row: Int) -> Int? {
        guard row >= 0, row != nowRow else { return nil }
        let index = row - (nowRow.map { row > $0 ? 1 : 0 } ?? 0)
        return agendaItems.indices.contains(index) ? index : nil
    }
    private func agendaRow(_ index: Int) -> Int {
        index + (nowRow.map { index >= $0 ? 1 : 0 } ?? 0)
    }
    private func updateAgendaClock(_ now: Date) {
        let selected = selectedEvent?.mark.id
        let origin = agendaScroll.contentView.bounds.origin
        agendaNow = now
        nowRow = agendaLayout == .right && Calendar.current.isDate(grid.date, inSameDayAs: now)
            ? agendaItems.firstIndex { $0.mark.span == .timed && $0.mark.start > now } ?? agendaItems.count : nil
        agenda.reloadData(); agenda.deselectAll(nil)
        if let index = agendaItems.firstIndex(where: { $0.mark.id == selected }) {
            agenda.selectRowIndexes(IndexSet(integer: agendaRow(index)), byExtendingSelection: false)
        }
        agendaScroll.contentView.scroll(to: origin)
        agendaScroll.reflectScrolledClipView(agendaScroll.contentView)
    }
    private func eventProgress(_ event: SampleEvent) -> Double? {
        guard agendaLayout == .right, Calendar.current.isDate(grid.date, inSameDayAs: agendaNow),
              event.mark.span == .timed, event.mark.start <= agendaNow, event.mark.end > agendaNow else { return nil }
        return agendaNow.timeIntervalSince(event.mark.start) / event.mark.end.timeIntervalSince(event.mark.start)
    }
    deinit { clockTask?.cancel() }

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
            return (source.key, (name: source.name, color: source.tint))
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
        let selected = selectedEvent?.mark.id
        agenda.deselectAll(nil)
        let visible = visibleEvents()
        grid.items = visible.map(\.mark)
        captionFormat.dateFormat = grid.period == .month ? "MMMM yyyy" : "d MMMM yyyy"
        caption.stringValue = captionFormat.string(from: grid.date)
        dayCaption.stringValue = dateFormat.string(from: grid.date) + (mode == .demo ? "  ·  SAMPLE EVENTS" : (events.count == 2000 ? "  ·  2,000 shown" : ""))
        dayCaption.toolTip = dayCaption.stringValue
        for (index, button) in modeButtons.enumerated() {
            button.state = ClassicCalendarPeriod.allCases[index] == grid.period ? .on : .off
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: grid.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        agendaItems = visible.filter { $0.mark.start < end && $0.mark.end > start }.sorted { $0.mark.start < $1.mark.start }
        updateAgendaClock(Date())
        if let index = agendaItems.firstIndex(where: { $0.mark.id == selected }) {
            agenda.selectRowIndexes(IndexSet(integer: agendaRow(index)), byExtendingSelection: false)
        }
        detail.stringValue = agendaItems.isEmpty ? mode == .demo ? "No sample events on this day." : "No events on this day. Refresh checks connected calendars." : "Select an event for details."
    }

    private func buildAgenda() {
        configureAgenda()
        agenda.style = .plain
        agenda.usesAutomaticRowHeights = false
        agenda.gridStyleMask = [.solidHorizontalGridLineMask]
        agenda.gridColor = ClassicTheme.grid
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

    private func configureAgenda() {
        for column in agenda.tableColumns { agenda.removeTableColumn(column) }
        let columns: [(AgendaColumn, String, Double)] = [(.time, "Time", 140), (.title, "Event", 470),
                                                       (.calendar, "Calendar", 210), (.location, "Location", 250)]
        for (id, title, width) in agendaLayout == .right ? [(.summary, "Events", 300)] : columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.width = width
            column.headerCell = ClassicHeaderCell(textCell: title)
            agenda.addTableColumn(column)
        }
        agenda.rowHeight = agendaLayout == .right ? 65 : 25
        agenda.headerView = agendaLayout == .right ? nil : agendaHeader
        agendaScroll.hasHorizontalScroller = agendaLayout == .below
        updateAgendaClock(Date())
    }

    private let spanFormat: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "d MMM HH:mm"; return value
    }()
    private func agendaTime(_ mark: ClassicCalendarMark) -> String {
        if mark.span == .allDay { return "All day" }
        if Calendar.current.isDate(mark.start, inSameDayAs: mark.end) { return timeFormat.string(from: mark.start) + " - " + timeFormat.string(from: mark.end) }
        return spanFormat.string(from: mark.start) + " - " + spanFormat.string(from: mark.end)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { agendaItems.count + (nowRow == nil ? 0 : 1) }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { row == nowRow ? 24 : agenda.rowHeight }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { eventIndex(row) != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: Self.rowID, owner: self) as? ClassicRow) ?? ClassicRow()
        view.identifier = Self.rowID
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == nowRow {
            let id = NSUserInterfaceItemIdentifier("agenda-now")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AgendaNowCell) ?? AgendaNowCell()
            cell.identifier = id; cell.configure("Now " + timeFormat.string(from: agendaNow))
            return cell
        }
        guard let index = eventIndex(row), let column = tableColumn else { return nil }
        let event = agendaItems[index]
        let time = agendaTime(event.mark)
        if agendaLayout == .right {
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? AgendaSummaryCell) ?? AgendaSummaryCell()
            cell.identifier = column.identifier
            cell.configure(event.mark.title, time: time, source: event.sourceName + (event.location.isEmpty ? "" : " · " + event.location), progress: eventProgress(event))
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? ClassicTableCell) ?? ClassicTableCell()
        cell.identifier = column.identifier
        switch AgendaColumn(rawValue: column.identifier.rawValue) {
        case .time: cell.configure(time)
        case .title: cell.configure(event.mark.title, weight: .bold)
        case .calendar: cell.configure(event.sourceName)
        case .location, .summary, .none: cell.configure(event.location)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        editEvent.isEnabled = mode == .live && selectedEvent?.key != nil
        guard let event = selectedEvent else { return }
        detail.stringValue = event.notes
    }

    @objc private func editSelected() {
        guard let key = selectedEvent?.key else { return }
        onEdit?(key)
    }

    func selfTest() throws {
        try verifyAgendaLayout()
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

private final class AgendaSplit: NSSplitView {
    var onDragEnd: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onDragEnd?()
    }
    override func drawDivider(in rect: NSRect) {
        ClassicTheme.face.setFill(); rect.fill()
        ClassicTheme.shadow.setFill()
        for offset: CGFloat in [-5, 0, 5] {
            NSRect(x: floor(rect.midX) + (isVertical ? 0 : offset), y: floor(rect.midY) + (isVertical ? offset : 0), width: 2, height: 2).fill()
        }
    }
}

private final class AgendaSummaryCell: NSTableCellView {
    private let time = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private var progress: Double?
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [time, title, source] { field.lineBreakMode = .byTruncatingTail; addSubview(field) }
        time.font = ClassicTheme.font(10); title.font = ClassicTheme.font(12, weight: .bold); source.font = ClassicTheme.font(10)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ value: String, time: String, source: String, progress: Double?) {
        self.progress = progress; needsDisplay = true
        title.stringValue = value; self.time.stringValue = time; self.source.stringValue = source
        toolTip = [time, value, source].joined(separator: " · ")
        setAccessibilityLabel(toolTip); needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let progress else { return }
        (backgroundStyle == .emphasized ? NSColor.white.withAlphaComponent(0.3) : ClassicTheme.grid).setFill()
        NSRect(x: 8, y: bounds.height - 3, width: max(0, bounds.width - 16), height: 2).fill()
        (backgroundStyle == .emphasized ? NSColor.white : ClassicTheme.timeMarker).setFill()
        NSRect(x: 8, y: bounds.height - 3, width: max(0, bounds.width - 16) * progress, height: 2).fill()
    }
    private func updateColors() {
        title.textColor = backgroundStyle == .emphasized ? .white : ClassicTheme.ink
        for field in [time, source] { field.textColor = backgroundStyle == .emphasized ? .white : ClassicTheme.muted }
    }
    override func layout() {
        super.layout()
        for (field, y, height) in [(time, 5.0, 16.0), (title, 23.0, 19.0), (source, 45.0, 16.0)] {
            field.frame = NSRect(x: 8, y: y, width: max(0, bounds.width - 16), height: height)
        }
    }
}

private final class AgendaNowCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = ClassicTheme.font(10, weight: .bold)
        label.textColor = ClassicTheme.timeMarker; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ text: String) {
        label.stringValue = text; setAccessibilityLabel(text); needsDisplay = true
    }
    override func layout() { super.layout(); label.frame = NSRect(x: 8, y: 4, width: 76, height: 17) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ClassicTheme.timeMarker.setFill()
        NSRect(x: 86, y: 12, width: max(0, bounds.width - 94), height: 2).fill()
    }
}
