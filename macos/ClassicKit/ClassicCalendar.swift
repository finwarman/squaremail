import AppKit

public enum ClassicCalendarPeriod: CaseIterable { case month, week, day }

public struct ClassicCalendarMark {
    public enum Span { case timed, allDay }
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let color: NSColor
    public let span: Span

    public init(id: String, title: String, start: Date, end: Date, color: NSColor, span: Span = .timed) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.color = color; self.span = span
    }
}

private final class CalendarHitButton: NSButton {
    var onPress: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.pushOnPushOff)
        focusRingType = .none
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func draw(_ dirtyRect: NSRect) {}
    @objc private func pressed() { onPress?() }
}

/// One painted grid with reusable native hit targets, independent of mail/providers.
public final class ClassicCalendar: NSView {
    public enum Density { case regular, compact }
    public var date = Date() { didSet { refresh() } }
    public var period: ClassicCalendarPeriod = .month { didSet { refresh() } }
    public var items: [ClassicCalendarMark] = [] { didSet { refresh() } }
    public var onSelectDate: ((Date) -> Void)?
    public var onSelectItem: ((String) -> Void)?
    public var visibleDates: [Date] {
        let start: Date
        switch period {
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!.start
            let offset = (calendar.component(.weekday, from: month) + 5) % 7
            start = calendar.date(byAdding: .day, value: -offset, to: month)!
        case .week: start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        case .day: start = calendar.startOfDay(for: date)
        }
        let count = period == .month ? 42 : (period == .week ? 7 : 1)
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private let density: Density
    private var calendar = Calendar(identifier: .iso8601)
    private let buttons = (0..<42).map { _ in CalendarHitButton() }
    private var hits: [(NSRect, String)] = []
    private var dirty = true
    private var dailyMarks: [Date: [ClassicCalendarMark]] = [:]
    private let dayFormat = DateFormatter()
    private let timeFormat = DateFormatter()
    private let headerFormat = DateFormatter()
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    public init(density: Density = .regular) {
        self.density = density
        super.init(frame: .zero)
        calendar.timeZone = .autoupdatingCurrent
        dayFormat.dateFormat = "EEEE d MMMM yyyy"
        timeFormat.dateFormat = "HH:mm"
        for (index, button) in buttons.enumerated() {
            button.onPress = { [weak self] in self?.chooseDay(index) }
            addSubview(button)
        }
        setAccessibilityLabel("Calendar")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(density:)") }

    private var headingHeight: CGFloat { density == .compact ? 20 : 30 }

    public override func layout() {
        super.layout()
        if dirty { updateDays() }
        guard bounds.width > 0, bounds.height > headingHeight else {
            buttons.forEach { $0.isHidden = true }
            return
        }
        let dates = visibleDates
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= dates.count
            if index < dates.count { button.frame = dayRect(index) }
        }
        needsDisplay = true
    }

    private func refresh() {
        dirty = true
        needsLayout = true
        needsDisplay = true
    }

    private func updateDays() {
        dirty = false
        let format = period == .day ? "EEEE d MMMM" : "EEE d"
        if headerFormat.dateFormat != format { headerFormat.dateFormat = format }
        let dates = visibleDates
        dailyMarks.removeAll(keepingCapacity: true)
        for day in dates {
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            dailyMarks[day] = items.filter { $0.start < end && $0.end > day }.sorted { $0.start < $1.start }
        }
        for (index, button) in buttons.enumerated() where index < dates.count {
            let marks = marksOn(dates[index])
            let label = dayFormat.string(from: dates[index]) + (marks.isEmpty ? "" : ": " + marks.map(\.title).joined(separator: ", "))
            button.title = label
            button.state = calendar.isDate(dates[index], inSameDayAs: date) ? .on : .off
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    private func marksOn(_ day: Date) -> [ClassicCalendarMark] {
        dailyMarks[day] ?? []
    }

    private func dayRect(_ index: Int) -> NSRect {
        if period == .month {
            let width = bounds.width / 7
            let height = (bounds.height - headingHeight) / 6
            return NSRect(x: CGFloat(index % 7) * width, y: headingHeight + CGFloat(index / 7) * height,
                          width: width, height: height).integral
        }
        let width = (bounds.width - 42) / CGFloat(period == .week ? 7 : 1)
        return NSRect(x: 42 + CGFloat(index) * width, y: 0, width: width, height: bounds.height).integral
    }

    private func chooseDay(_ index: Int) {
        let dates = visibleDates
        guard dates.indices.contains(index) else { return }
        let chosen = dates[index]
        let hit: String?
        if let event = NSApp.currentEvent, event.type == .leftMouseUp {
            let point = convert(event.locationInWindow, from: nil)
            hit = hits.first(where: { $0.0.contains(point) })?.1
        } else { hit = nil }
        date = chosen
        onSelectDate?(chosen)
        if let hit { onSelectItem?(hit) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if dirty { updateDays() }
        NSColor.white.setFill(); bounds.fill()
        hits.removeAll(keepingCapacity: true)
        if period == .month { drawMonth() } else { drawTimeGrid() }
    }

    private func drawMonth() {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let width = bounds.width / 7
        ClassicTheme.face.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: headingHeight).fill()
        for index in 0..<7 {
            if calendar.isDate(date, equalTo: Date(), toGranularity: .month), index == (calendar.component(.weekday, from: Date()) + 5) % 7 {
                ClassicTheme.todaySurface.setFill()
                NSRect(x: CGFloat(index) * width, y: 0, width: width, height: headingHeight).fill()
            }
            ClassicTheme.text(names[index], in: NSRect(x: CGFloat(index) * width, y: 5, width: width, height: 18),
                              size: density == .compact ? 9 : 11, color: ClassicTheme.muted, alignment: .center)
        }
        for (index, day) in visibleDates.enumerated() {
            let rect = dayRect(index)
            let inMonth = calendar.isDate(day, equalTo: date, toGranularity: .month)
            if !inMonth { ClassicTheme.row.setFill(); rect.fill() }
            if calendar.isDate(day, inSameDayAs: date) { ClassicTheme.selectedSurface.setFill(); rect.fill() }
            ClassicTheme.grid.setStroke()
            NSBezierPath(rect: rect).stroke()
            let dayNumber = String(calendar.component(.day, from: day))
            let today = calendar.isDateInToday(day)
            if today {
                ClassicTheme.navy.setFill()
                NSRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: density == .compact ? rect.height - 2 : 24).fill()
            }
            let number = density == .compact ? rect.insetBy(dx: 1, dy: 4) : NSRect(x: rect.minX + 6, y: rect.minY + 5, width: rect.width - 12, height: 19)
            ClassicTheme.text(dayNumber, in: number, size: density == .compact ? 10 : 12,
                              color: today ? .white : (inMonth ? ClassicTheme.ink : ClassicTheme.muted),
                              weight: today ? .bold : .regular, alignment: density == .compact ? .center : .left)
            if calendar.isDate(day, inSameDayAs: date) {
                ClassicTheme.focus.setStroke()
                let selection = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)); selection.lineWidth = 2; selection.stroke()
            }
            if density == .compact { continue }
            let marks = marksOn(day)
            let capacity = max(0, Int((rect.height - 27) / 19))
            for (offset, item) in marks.prefix(capacity).enumerated() {
                let event = NSRect(x: rect.minX + 4, y: rect.minY + 26 + CGFloat(offset) * 19, width: rect.width - 8, height: 17)
                let title = item.span == .allDay ? item.title : timeFormat.string(from: item.start) + " " + item.title
                drawMark(item, title, event)
            }
            if marks.count > capacity {
                ClassicTheme.text("+\(marks.count - capacity) more", in: NSRect(x: rect.minX + 6, y: rect.maxY - 17, width: rect.width - 12, height: 16), size: 9, color: ClassicTheme.muted)
            }
        }
    }

    private func drawTimeGrid() {
        let dates = visibleDates
        let left: CGFloat = 42
        let allDayHeight: CGFloat = 24
        let top = headingHeight + allDayHeight
        let hourHeight = max(1, (bounds.height - top) / 24)
        let width = (bounds.width - left) / CGFloat(dates.count)
        ClassicTheme.face.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: top).fill()
        ClassicTheme.text("All day", in: NSRect(x: 2, y: headingHeight + 5, width: 38, height: 14), size: 8, color: ClassicTheme.muted)
        for (index, day) in dates.enumerated() where calendar.isDateInToday(day) {
            ClassicTheme.todaySurface.setFill()
            NSRect(x: left + CGFloat(index) * width, y: top, width: width, height: max(0, bounds.height - top)).fill()
        }
        let now = Date()
        if let index = dates.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) {
            ClassicTheme.color(0xFFF0DA).setFill()
            NSRect(x: left + CGFloat(index) * width, y: top + floor(clockHour(now)) * hourHeight, width: width, height: hourHeight).fill()
        }
        for hour in 0..<24 {
            let y = top + CGFloat(hour) * hourHeight
            ClassicTheme.color(0xE5E3DD).setFill()
            NSRect(x: left, y: y, width: bounds.width - left, height: 1).fill()
            if hourHeight >= 16 || hour % 2 == 0 {
                ClassicTheme.text(String(format: "%02d:00", hour), in: NSRect(x: 2, y: y + 1, width: 37, height: 15), size: 9, color: ClassicTheme.muted)
            }
        }
        for (index, day) in dates.enumerated() {
            let x = left + CGFloat(index) * width
            if calendar.isDateInToday(day) {
                ClassicTheme.navy.setFill()
                NSRect(x: x, y: 0, width: width, height: headingHeight).fill()
            }
            if calendar.isDate(day, inSameDayAs: date) {
                ClassicTheme.blue.setFill()
                NSRect(x: x + 1, y: headingHeight - 3, width: width - 2, height: 3).fill()
            }
            ClassicTheme.text(headerFormat.string(from: day), in: NSRect(x: x + 3, y: 6, width: width - 6, height: 18),
                              size: 12, color: calendar.isDateInToday(day) ? .white : ClassicTheme.ink, weight: .bold, alignment: .center)
            ClassicTheme.grid.setFill()
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
            let marks = marksOn(day)
            for item in marks.filter({ $0.span == .allDay }).prefix(1) {
                drawMark(item, item.title, NSRect(x: x + 3, y: headingHeight + 2, width: width - 6, height: 18))
            }
            var laneEnds: [Date] = []
            var placed: [(ClassicCalendarMark, Int)] = []
            for item in marks where item.span == .timed {
                let lane = laneEnds.firstIndex(where: { $0 <= item.start }) ?? laneEnds.count
                if lane == laneEnds.count { laneEnds.append(item.end) } else { laneEnds[lane] = item.end }
                placed.append((item, lane))
            }
            let laneWidth = (width - 6) / CGFloat(max(1, laneEnds.count))
            for (item, lane) in placed {
                let start = calendar.isDate(item.start, inSameDayAs: day) ? clockHour(item.start) : 0
                let end = calendar.isDate(item.end, inSameDayAs: day) ? clockHour(item.end) : 24
                let rect = NSRect(x: x + 3 + CGFloat(lane) * laneWidth, y: top + start * hourHeight,
                                  width: laneWidth - 1, height: max(16, (end - start) * hourHeight - 1)).integral
                drawMark(item, item.title, rect)
            }
        }
        if let index = dates.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) {
            let y = top + clockHour(now) * hourHeight
            ClassicTheme.timeMarker.setFill()
            NSRect(x: left + CGFloat(index) * width, y: floor(y), width: width, height: 2).fill()
            ClassicTheme.text(timeFormat.string(from: now), in: NSRect(x: 0, y: min(bounds.height - 15, max(top, y - 7)), width: left - 3, height: 15), size: 9, color: ClassicTheme.timeMarker, weight: .bold, alignment: .right)
        }
    }

    private func clockHour(_ date: Date) -> CGFloat {
        let value = calendar.dateComponents([.hour, .minute], from: date)
        return CGFloat(value.hour ?? 0) + CGFloat(value.minute ?? 0) / 60
    }

    private func drawMark(_ item: ClassicCalendarMark, _ title: String, _ rect: NSRect) {
        item.color.withAlphaComponent(0.15).setFill(); rect.fill()
        item.color.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        ClassicTheme.text(title, in: NSRect(x: rect.minX + 6, y: rect.minY + 1, width: rect.width - 9, height: 16), size: 10)
        NSGraphicsContext.restoreGraphicsState()
        hits.append((rect, item.id))
    }
}
