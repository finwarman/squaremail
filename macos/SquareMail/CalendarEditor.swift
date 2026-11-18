import AppKit
import ClassicKit

@MainActor
final class CalendarEditor: NSObject, NSWindowDelegate {
    private let core: MailCore
    private var window: NSPanel?
    private var task: Task<Void, Never>?
    private var detail: EventDetail?
    private var key: EventKey?
    private var sources: [CalendarSource] = []
    private var accounts: [Account] = []
    private let source = NSPopUpButton(frame: .zero)
    private let title = NSTextField(frame: .zero)
    private let location = NSTextField(frame: .zero)
    private let start = NSDatePicker(frame: .zero)
    private let end = NSDatePicker(frame: .zero)
    private let zone = NSTextField(frame: .zero)
    private let allDay = NSButton(checkboxWithTitle: "All-day event (end date is exclusive)", target: nil, action: nil)
    private let guests = NSButton(checkboxWithTitle: "I want to send this change to the existing attendees", target: nil, action: nil)
    private let reminder = NSPopUpButton(frame: .zero)
    private let metadata = NSTextView(usingTextLayoutManager: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let save = ClassicButton("Save to calendar")
    private let consent = ClassicButton("Enable calendar editing…")
    private let reload = ClassicButton("Refresh details")
    private let cancel = ClassicButton("Cancel")
    private var generation = 0
    private var selectedDate = Date()
    private var operation = UUID().uuidString.lowercased()
    private static let offsets = [0, 5, 10, 15, 30, 60, 1440]
    var onQueued: (() -> Void)?
    var onStatus: ((String) -> Void)?

    init(core: MailCore) { self.core = core; super.init() }
    func close() { generation += 1; task?.cancel(); task = nil; window?.delegate = nil; window?.close(); window = nil; detail = nil }
    func windowWillClose(_ notification: Notification) { close() }
    func open(_ key: EventKey?, date: Date, sources: [CalendarSource], accounts: [Account]) {
        close()
        self.key = key; selectedDate = date
        self.sources = sources.filter { source in accounts.contains { $0.id == source.accountId && $0.provider != .local } }
        self.accounts = accounts
        operation = UUID().uuidString.lowercased()
        build()
        source.removeAllItems()
        for item in self.sources {
            let email = accounts.first { $0.id == item.accountId }?.email ?? ""
            source.addItem(withTitle: item.name + " · " + email)
            if item.accountId == key?.account && item.id == key?.calendar { source.select(source.lastItem) }
        }
        source.isEnabled = key?.id == nil
        if key == nil, let first = self.sources.first { self.key = EventKey(account: first.accountId, calendar: first.id, id: nil) }
        title.stringValue = ""; location.stringValue = ""
        start.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        end.dateValue = start.dateValue.addingTimeInterval(3600)
        zone.stringValue = TimeZone.current.identifier
        allDay.state = .off; guests.state = .off; reminder.selectItem(at: 0)
        updateTimeFields()
        window?.center(); window?.makeKeyAndOrderFront(nil)
        load(.cached)
    }
    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = key?.id == nil ? "New calendar event" : "Edit calendar event"
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let form = panel.contentView!
        form.wantsLayer = true; form.layer?.backgroundColor = ClassicTheme.face.cgColor
        func row(_ label: String, _ view: NSView, _ y: CGFloat) {
            let caption = NSTextField(labelWithString: label)
            caption.font = ClassicTheme.font(11)
            caption.frame = NSRect(x: 14, y: y + 3, width: 108, height: 20)
            view.frame = NSRect(x: 125, y: y, width: 535, height: 26)
            form.addSubview(caption); form.addSubview(view)
        }
        row("Calendar:", source, 606); row("Title:", title, 568); row("Location:", location, 530)
        row("Starts:", start, 492); row("Ends:", end, 454); row("Time zone:", zone, 416)
        allDay.frame = NSRect(x: 125, y: 382, width: 535, height: 24)
        row("Reminder:", reminder, 345)
        reminder.removeAllItems(); reminder.addItems(withTitles: ["Keep provider reminder", "Off", "At event start", "5 minutes before", "10 minutes before", "15 minutes before", "30 minutes before", "1 hour before", "1 day before"])
        source.target = self; source.action = #selector(changeSource)
        zone.target = self; zone.action = #selector(updateTimeFields)
        allDay.target = self; allDay.action = #selector(updateTimeFields)
        for picker in [start, end] { picker.datePickerStyle = .textFieldAndStepper; picker.drawsBackground = true }
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 173, width: 646, height: 155))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = metadata
        metadata.isEditable = false; metadata.isSelectable = true; metadata.isRichText = false
        metadata.font = ClassicTheme.font(11); metadata.textContainerInset = NSSize(width: 8, height: 8)
        metadata.textColor = ClassicTheme.ink; metadata.backgroundColor = .white
        metadata.frame = NSRect(origin: .zero, size: scroll.contentSize)
        metadata.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        metadata.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        metadata.autoresizingMask = [.width]; metadata.isVerticallyResizable = true
        metadata.textContainer?.widthTracksTextView = true
        guests.frame = NSRect(x: 14, y: 140, width: 646, height: 24)
        status.frame = NSRect(x: 14, y: 82, width: 646, height: 52)
        status.font = ClassicTheme.font(10); status.textColor = ClassicTheme.muted
        consent.frame = NSRect(x: 14, y: 44, width: 210, height: 28)
        reload.frame = NSRect(x: 232, y: 44, width: 130, height: 28)
        save.frame = NSRect(x: 378, y: 44, width: 170, height: 28)
        cancel.frame = NSRect(x: 556, y: 44, width: 104, height: 28)
        consent.onPress = { [weak self] in self?.enableEditing() }
        reload.onPress = { [weak self] in self?.load(.fetch) }
        save.onPress = { [weak self] in self?.submit() }
        cancel.onPress = { [weak self] in self?.close() }
        for view in [allDay, scroll, guests, status, consent, reload, save, cancel] { form.addSubview(view) }
        let note = NSTextField(labelWithString: "Offline saves stay queued. Conflicts stop for review. Mail remains read-only.")
        note.frame = NSRect(x: 14, y: 12, width: 646, height: 20); note.font = ClassicTheme.font(10)
        form.addSubview(note)
        window = panel
    }
    @objc private func changeSource() {
        guard sources.indices.contains(source.indexOfSelectedItem) else { return }
        let value = sources[source.indexOfSelectedItem]
        key = EventKey(account: value.accountId, calendar: value.id, id: nil)
        detail = nil
        load(.cached)
    }
    private func load(_ mode: BodyFetch) {
        task?.cancel(); generation += 1
        guard let key else { status.stringValue = "Connect and sync a calendar first."; save.isEnabled = false; return }
        let revision = generation
        save.isEnabled = false; status.stringValue = "Loading event metadata…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var reply: EventDetailReply = try await core.request(["command": CoreCommand.eventDetail.rawValue, "key": key.command, "mode": mode.rawValue], mode: .live, queue: mode == .cached ? .local : .calendar)
                if mode == .cached, reply.detail == nil {
                    reply = try await core.request(["command": CoreCommand.eventDetail.rawValue, "key": key.command, "mode": BodyFetch.fetch.rawValue], mode: .live, queue: .calendar)
                }
                guard !Task.isCancelled, generation == revision, let value = reply.detail else { return }
                detail = value
                if key.id != nil { fill(value) }
                else { metadata.string = "A new personal event. Attendees and recurrence creation are not part of this editor." }
                save.isEnabled = value.writable
                status.stringValue = value.writable ? "Metadata cached. Saving checks the provider revision. Recurring events edit this occurrence only." : "This event or calendar is read-only. Provider permissions and organiser restrictions apply."
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }
    private func fill(_ value: EventDetail) {
        title.stringValue = value.draft.title; location.stringValue = value.draft.location
        zone.stringValue = value.draft.time.zone ?? TimeZone.current.identifier
        allDay.state = value.draft.time.kind == .allDay ? .on : .off
        updateTimeFields()
        func date(_ value: EventTime.TimeValue) -> Date {
            switch value {
            case .instant(let seconds): return Date(timeIntervalSince1970: TimeInterval(seconds))
            case .day(let text): return dayFormat().date(from: text) ?? selectedDate
            }
        }
        start.dateValue = date(value.draft.time.start); end.dateValue = date(value.draft.time.end)
        guests.isEnabled = value.participantCount > 0
        guests.state = .off
        metadata.string = "Organiser: " + value.organizer + "\n" + (value.recurring ? "Recurring occurrence. Series data is preserved.\n" : "") + "Attendees (\(value.participantCount)): " + value.participants.joined(separator: ", ") + "\n" + value.conference + "\n" + value.notes
    }
    @objc private func updateTimeFields() {
        let tz = TimeZone(identifier: zone.stringValue) ?? .current
        for picker in [start, end] {
            picker.timeZone = tz
            picker.datePickerElements = allDay.state == .on ? [.yearMonthDay] : [.yearMonthDay, .hourMinute]
        }
    }
    private func dayFormat() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone.stringValue) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    private func submit() {
        guard let key, let detail, detail.writable else { return }
        if detail.participantCount > 0, guests.state != .on { status.stringValue = "Approve attendee updates before saving this meeting."; return }
        let change = makeChange(key, detail: detail)
        save.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.queueEvent.rawValue, "change": try change.command()], mode: .live)
                onQueued?(); onStatus?("Calendar change queued. It will sync while online."); close()
            } catch { status.stringValue = error.localizedDescription; save.isEnabled = true }
        }
    }
    private func makeChange(_ key: EventKey, detail: EventDetail) -> EventChange {
        let time = allDay.state == .on ? EventTime(kind: .allDay, start: .day(dayFormat().string(from: start.dateValue)), end: .day(dayFormat().string(from: end.dateValue)), zone: zone.stringValue) : EventTime(kind: .timed, start: .instant(Int64(start.dateValue.timeIntervalSince1970)), end: .instant(Int64(end.dateValue.timeIntervalSince1970)), zone: zone.stringValue)
        let index = reminder.indexOfSelectedItem
        let reminder = EventReminder(kind: index == 0 ? .preserve : (index == 1 ? .off : .minutes), minutes: index >= 2 ? Self.offsets[index - 2] : nil)
        return EventChange(operation: operation, key: key, revision: key.id == nil ? nil : detail.revision, draft: EventDraft(title: title.stringValue, location: location.stringValue, time: time, reminder: reminder), updates: guests.state == .on ? .notify : .personal)
    }
    func verify() async throws {
        await task?.value
        guard let detail, let key, detail.organizer == "Team", detail.participants == ["Ada (accepted)"], title.stringValue == "Original", metadata.string.contains("Team"), metadata.bounds.width > 0, metadata.bounds.height > 0 else {
            throw MailError(message: "Cached event metadata did not populate the native editor")
        }
        title.stringValue = "Native edited title"
        let change = makeChange(key, detail: detail)
        guard change.draft.title == "Native edited title", change.draft.time == detail.draft.time, change.draft.reminder.kind == .preserve, change.key == key else {
            throw MailError(message: "Native editor changed untouched event fields")
        }
        title.stringValue = detail.draft.title
    }

    private func enableEditing() {
        guard let key else { return }
        task?.cancel()
        consent.isEnabled = false
        status.stringValue = "Waiting for calendar-write consent in your browser. Existing mail access stays read-only."
        task = Task { [weak self] in
            guard let self else { return }
            defer { consent.isEnabled = true }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.calendarConsent.rawValue, "account": key.account], mode: .live, queue: .login)
                onQueued?()
                status.stringValue = "Calendar editing enabled. Save when ready."
            } catch is CancellationError {} catch { status.stringValue = error.localizedDescription }
        }
    }
}
