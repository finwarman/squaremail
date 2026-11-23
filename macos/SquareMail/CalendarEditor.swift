import AppKit
import ClassicKit

@MainActor
final class CalendarEditor: NSObject, NSWindowDelegate {
    enum CloseOutcome { case closed, cancelled }
    private enum FormLoad { case replace, preserve }
    private enum Phase { case closed, loading, ready, saving, savingDraft, authorizing, prompting }
    private struct Form: Equatable {
        let title: String; let location: String; let start: Date; let end: Date; let zone: String
        let allDay: Int; let reminder: Int; let guests: Int; let calendar: String?
    }
    private let prompts: EditorPrompting
    private var phase: Phase = .closed
    private var baseline: Form?
    private var savedLocally = false
    private let saveDraft = ClassicButton("Save draft")
    private let core: MailCore
    private var window: NSPanel?
    private var task: Task<Void, Never>?
    private var detail: EventDetail?
    private var key: EventKey?
    private var sources: [CalendarSource] = []
    private var accounts: [Account] = []
    private let source = NSPopUpButton(frame: .zero)
    private let sourceLabel = NSTextField(labelWithString: "")
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

    init(core: MailCore, prompts: EditorPrompting? = nil) {
        self.core = core; self.prompts = prompts ?? EditorPrompter(); super.init()
    }
    var requiresClosePrompt: Bool { window != nil && (isDirty || phase == .saving || phase == .savingDraft) }
    private var form: Form {
        Form(title: title.currentEditor()?.string ?? title.stringValue, location: location.currentEditor()?.string ?? location.stringValue,
             start: start.dateValue, end: end.dateValue, zone: zone.currentEditor()?.string ?? zone.stringValue,
             allDay: allDay.state.rawValue, reminder: reminder.indexOfSelectedItem, guests: guests.state.rawValue, calendar: key?.calendar)
    }
    private var isDirty: Bool { baseline.map { $0 != form } ?? false }
    func close() {
        generation += 1; task?.cancel(); task = nil
        phase = .closed
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort) }
        window?.delegate = nil; window?.close(); window = nil; detail = nil; baseline = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    func windowWillClose(_ notification: Notification) { close() }
    func requestClose(_ completion: @escaping (CloseOutcome) -> Void = { _ in }) {
        if phase == .saving || phase == .savingDraft { status.stringValue = "Saving. Please wait before closing."; completion(.cancelled); return }
        if phase == .prompting { completion(.cancelled); return }
        if phase == .authorizing { task?.cancel(); generation += 1; transition(.ready) }
        guard isDirty, let window else { close(); completion(.closed); return }
        let alert = NSAlert()
        alert.messageText = "Save your calendar draft?"
        alert.informativeText = "Save a local draft, discard changes since the last save, or keep editing. A local draft does not change the provider calendar."
        alert.addButton(withTitle: "Save draft"); alert.addButton(withTitle: "Discard changes"); alert.addButton(withTitle: "Keep editing")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        transition(.prompting)
        prompts.choose(alert, window: window) { [weak self] response in
            guard let self, self.window === window, phase == .prompting else { completion(.cancelled); return }
            transition(.ready)
            if response != .alertFirstButtonReturn && response != .alertSecondButtonReturn { completion(.cancelled); return }
            if response == .alertSecondButtonReturn { close(); completion(.closed); return }
            storeDraft { [weak self] outcome in
                if outcome == .closed { self?.close() }
                completion(outcome)
            }
        }
    }
    func open(_ key: EventKey?, date: Date, sources: [CalendarSource], accounts: [Account]) {
        if window != nil, self.key == key || (key == nil && self.key?.id == nil) { if let window { WindowPresentation.show(window) }; return }
        requestClose { [weak self] outcome in
            guard outcome == .closed else { return }
            self?.present(key, date: date, sources: sources, accounts: accounts)
        }
    }
    func openDraft(_ draft: LocalEventDraft, sources: [CalendarSource], accounts: [Account]) {
        if window != nil, operation == draft.change.operation { if let window { WindowPresentation.show(window) }; return }
        requestClose { [weak self] outcome in
            guard let self, outcome == .closed else { return }
            present(draft.change.key, date: Date(), sources: sources, accounts: accounts, draft: draft)
        }
    }
    private func present(_ key: EventKey?, date: Date, sources: [CalendarSource], accounts: [Account], draft: LocalEventDraft? = nil) {
        self.key = key; selectedDate = date; savedLocally = draft != nil
        metadata.string = ""
        self.sources = sources.filter { source in accounts.contains { $0.id == source.accountId && $0.provider != .local } }
        self.accounts = accounts
        operation = draft?.change.operation ?? UUID().uuidString.lowercased()
        build()
        source.removeAllItems()
        for item in self.sources {
            let email = accounts.first { $0.id == item.accountId }?.email ?? ""
            source.addItem(withTitle: item.name + " · " + email)
            if item.accountId == key?.account && item.id == key?.calendar { source.select(source.lastItem) }
        }
        if key == nil, let first = self.sources.first { self.key = EventKey(account: first.accountId, calendar: first.id, id: nil) }
        title.stringValue = ""; location.stringValue = ""
        start.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        end.dateValue = start.dateValue.addingTimeInterval(3600)
        zone.stringValue = TimeZone.current.identifier
        allDay.state = .off; guests.state = .off; reminder.selectItem(at: 0)
        updateTimeFields()
        baseline = form
        window?.center(); if let window { WindowPresentation.show(window) }
        if let draft {
            detail = draft.base
            if let base = draft.base { fill(base) }
            fillForm(draft.change.draft)
            guests.state = draft.change.updates == .notify ? .on : .off
            baseline = form
            transition(.ready)
            status.stringValue = "Local draft restored. Save to calendar queues it for sync."
        } else { load(.cached) }
    }
    private func transition(_ phase: Phase) {
        self.phase = phase
        let ready = phase == .ready
        for control in [title, location, start, end, zone, allDay, reminder] as [NSControl] { control.isEnabled = ready }
        source.isEnabled = ready && key?.id == nil
        source.isHidden = key?.id != nil
        sourceLabel.isHidden = !source.isHidden
        sourceLabel.stringValue = source.titleOfSelectedItem ?? "Calendar unavailable"
        guests.isEnabled = ready && (detail?.participantCount ?? 0) > 0
        save.isEnabled = ready && detail?.writable == true
        saveDraft.isEnabled = ready && key != nil
        reload.isEnabled = ready && key != nil
        consent.isEnabled = ready && key != nil
        cancel.isEnabled = phase != .prompting
        cancel.title = phase == .authorizing ? "Cancel sign-in" : "Cancel"
        for button in [save, saveDraft, consent, reload, cancel] { button.needsDisplay = true }
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
            caption.textColor = ClassicTheme.ink
            caption.frame = NSRect(x: 14, y: y + 3, width: 108, height: 20)
            view.frame = NSRect(x: 125, y: y, width: 535, height: 26)
            form.addSubview(caption); form.addSubview(view)
        }
        row("Calendar:", source, 606); row("Title:", title, 568); row("Location:", location, 530)
        sourceLabel.frame = source.frame; sourceLabel.font = ClassicTheme.font(12); sourceLabel.textColor = ClassicTheme.ink
        sourceLabel.isSelectable = true; sourceLabel.isHidden = true; form.addSubview(sourceLabel)
        for field in [title, location, zone] {
            field.font = ClassicTheme.font(12); field.textColor = ClassicTheme.ink
            field.backgroundColor = .white; field.drawsBackground = true
        }
        row("Starts:", start, 492); row("Ends:", end, 454); row("Time zone:", zone, 416)
        allDay.frame = NSRect(x: 125, y: 382, width: 535, height: 24)
        row("Reminder:", reminder, 345)
        reminder.removeAllItems(); reminder.addItems(withTitles: ["Keep provider reminder", "Off", "At event start", "5 minutes before", "10 minutes before", "15 minutes before", "30 minutes before", "1 hour before", "1 day before"])
        source.target = self; source.action = #selector(changeSource)
        zone.target = self; zone.action = #selector(updateTimeFields)
        allDay.target = self; allDay.action = #selector(updateTimeFields)
        for picker in [start, end] {
            picker.datePickerStyle = .textFieldAndStepper; picker.drawsBackground = true
            picker.backgroundColor = .white; picker.textColor = ClassicTheme.ink; picker.font = ClassicTheme.font(12)
        }
        for checkbox in [allDay, guests] {
            checkbox.attributedTitle = NSAttributedString(string: checkbox.title, attributes: [.font: ClassicTheme.font(12), .foregroundColor: ClassicTheme.ink])
        }
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
        reload.onPress = { [weak self] in self?.refresh() }
        save.onPress = { [weak self] in self?.submit() }
        cancel.onPress = { [weak self] in self?.requestClose() }
        for view in [allDay, scroll, guests, status, consent, reload, save, cancel] { form.addSubview(view) }
        saveDraft.frame = NSRect(x: 14, y: 8, width: 130, height: 28)
        saveDraft.onPress = { [weak self] in self?.storeDraft() }
        form.addSubview(saveDraft)
        let note = NSTextField(labelWithString: "Drafts stay on this Mac until you choose Save to calendar.")
        note.frame = NSRect(x: 154, y: 12, width: 506, height: 20); note.font = ClassicTheme.font(10)
        note.textColor = ClassicTheme.muted
        form.addSubview(note)
        window = panel
    }
    @objc private func changeSource() {
        guard sources.indices.contains(source.indexOfSelectedItem) else { return }
        let value = sources[source.indexOfSelectedItem]
        key = EventKey(account: value.accountId, calendar: value.id, id: nil)
        detail = nil
        load(.cached, retention: .preserve)
    }
    private func load(_ mode: BodyFetch, retention: FormLoad = .replace) {
        task?.cancel(); generation += 1
        guard let key else { transition(.loading); status.stringValue = "Connect and sync a calendar first."; return }
        let revision = generation
        transition(.loading); status.stringValue = "Loading event metadata…"
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
                if retention == .replace { baseline = form }
                transition(.ready)
                status.stringValue = value.writable ? "Details loaded. Saving checks for newer changes. Recurring events edit this occurrence only." : "This event or calendar is read-only. Provider permissions and organiser restrictions apply."
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                transition(.ready)
                status.stringValue = error.localizedDescription
            }
        }
    }
    private func refresh() {
        guard phase == .ready, let window else { return }
        guard isDirty || savedLocally else { load(.fetch); return }
        let alert = NSAlert()
        alert.messageText = "Refresh provider details?"
        alert.informativeText = "Unsaved form changes will be discarded. A saved local draft remains available under Drafts / pending."
        alert.addButton(withTitle: "Refresh details"); alert.addButton(withTitle: "Keep editing")
        transition(.prompting)
        prompts.choose(alert, window: window) { [weak self] response in
            guard let self, self.window === window, phase == .prompting else { return }
            transition(.ready)
            if response == .alertFirstButtonReturn { load(.fetch) }
        }
    }
    private func fill(_ value: EventDetail) {
        fillForm(value.draft)
        guests.isEnabled = value.participantCount > 0
        guests.state = .off
        metadata.string = "Organiser: " + value.organizer + "\n" + (value.recurring ? "Recurring occurrence. Series data is preserved.\n" : "") + "Attendees (\(value.participantCount)): " + value.participants.joined(separator: ", ") + "\n" + value.conference + "\n" + value.notes
    }
    private func fillForm(_ draft: EventDraft) {
        title.stringValue = draft.title; location.stringValue = draft.location
        zone.stringValue = draft.time.zone ?? TimeZone.current.identifier
        allDay.state = draft.time.kind == .allDay ? .on : .off
        updateTimeFields()
        func date(_ value: EventTime.TimeValue) -> Date {
            switch value {
            case .instant(let seconds): return Date(timeIntervalSince1970: TimeInterval(seconds))
            case .day(let text): return dayFormat().date(from: text) ?? selectedDate
            }
        }
        start.dateValue = date(draft.time.start); end.dateValue = date(draft.time.end)
        switch draft.reminder.kind {
        case .preserve: reminder.selectItem(at: 0)
        case .off: reminder.selectItem(at: 1)
        case .minutes: reminder.selectItem(at: (Self.offsets.firstIndex(of: draft.reminder.minutes ?? 0) ?? 0) + 2)
        }
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
        guard phase == .ready, let key, let detail, detail.writable else { return }
        window?.makeFirstResponder(nil)
        if detail.participantCount > 0, guests.state != .on { status.stringValue = "Approve attendee updates before saving this meeting."; return }
        let change = makeChange(key, detail: detail)
        transition(.saving)
        generation += 1
        let revision = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.queueEvent.rawValue, "change": try change.command()], mode: .live)
                guard generation == revision else { return }
                onQueued?(); onStatus?("Calendar change queued. It will sync while online."); close()
            } catch {
                guard generation == revision else { return }
                transition(.ready); status.stringValue = error.localizedDescription
            }
        }
    }
    private func makeChange(_ key: EventKey, detail: EventDetail?) -> EventChange {
        let time = allDay.state == .on ? EventTime(kind: .allDay, start: .day(dayFormat().string(from: start.dateValue)), end: .day(dayFormat().string(from: end.dateValue)), zone: zone.stringValue) : EventTime(kind: .timed, start: .instant(Int64(start.dateValue.timeIntervalSince1970)), end: .instant(Int64(end.dateValue.timeIntervalSince1970)), zone: zone.stringValue)
        let index = reminder.indexOfSelectedItem
        let reminder = EventReminder(kind: index == 0 ? .preserve : (index == 1 ? .off : .minutes), minutes: index >= 2 ? Self.offsets[index - 2] : nil)
        return EventChange(operation: operation, key: key, revision: key.id == nil ? nil : detail?.revision, draft: EventDraft(title: title.stringValue, location: location.stringValue, time: time, reminder: reminder), updates: guests.state == .on ? .notify : .personal)
    }
    private func storeDraft(_ completion: @escaping (CloseOutcome) -> Void = { _ in }) {
        guard phase == .ready, let key else { completion(.cancelled); return }
        window?.makeFirstResponder(nil)
        let change = makeChange(key, detail: detail)
        transition(.savingDraft)
        generation += 1; let revision = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.saveEventDraft.rawValue, "change": try change.command()], mode: .live)
                guard generation == revision else { return }
                baseline = form; savedLocally = true
                transition(.ready); status.stringValue = "Draft saved on this Mac. It has not changed the provider calendar."
                completion(.closed)
            } catch {
                guard generation == revision else { return }
                transition(.ready); status.stringValue = error.localizedDescription
                completion(.cancelled)
            }
        }
    }
    func verify() async throws {
        await task?.value
        guard window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
              title.textColor == ClassicTheme.ink, start.textColor == ClassicTheme.ink,
              source.isHidden, !sourceLabel.isHidden, !sourceLabel.stringValue.isEmpty else { throw MailError(message: "Calendar form lost readable light appearance or calendar identity") }
        if let content = window?.contentView { try WindowPresentation.snapshot(content, name: "calendar-editor") }
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

    func verifyControls(_ probe: ScriptedEditorPrompts) async throws {
        try await verify()
        allDay.performClick(nil)
        guard allDay.state == .on, start.datePickerElements == [.yearMonthDay] else { throw MailError(message: "All-day toggle did not update date controls") }
        allDay.performClick(nil)
        title.stringValue = "Recoverable calendar draft"
        cancel.performClick(nil)
        guard phase == .prompting, probe.pending, probe.buttons == ["Save draft", "Discard changes", "Keep editing"] else { throw MailError(message: "Cancel did not present unsaved-edit choices") }
        let count = probe.presentations
        requestClose()
        guard probe.presentations == count else { throw MailError(message: "Repeated close created another prompt") }
        probe.respond(.alertThirdButtonReturn)
        guard phase == .ready, isDirty, cancel.isEnabled else { throw MailError(message: "Keep editing left the form blocked") }
        reload.performClick(nil)
        guard phase == .prompting, probe.lastTitle == "Refresh provider details?" else { throw MailError(message: "Refresh discarded unsaved values without a prompt") }
        probe.respond(.alertSecondButtonReturn)
        guard title.stringValue == "Recoverable calendar draft", phase == .ready else { throw MailError(message: "Refresh cancellation lost form values") }
        save.performClick(nil)
        guard phase == .ready, status.stringValue.contains("attendee") else { throw MailError(message: "Meeting save did not explain missing attendee approval") }
        window?.performClose(nil)
        guard probe.pending else { throw MailError(message: "Window close bypassed the unsaved-edit prompt") }
        probe.respond(.alertFirstButtonReturn)
        await task?.value
        guard window == nil else { throw MailError(message: "Saving a local draft did not finish closing") }
        let writes: [EventWrite] = try await core.request(["command": CoreCommand.eventWrites.rawValue], mode: .live)
        guard let draft = writes.first(where: { $0.state == .draft && $0.title == "Recoverable calendar draft" })?.draft else { throw MailError(message: "Local calendar draft was not persisted") }
        openDraft(draft, sources: sources, accounts: accounts)
        guard phase == .ready, !isDirty, title.stringValue == draft.change.draft.title else { throw MailError(message: "Reopening a local draft lost its form state") }
        title.stringValue = "Discard this newer change"
        cancel.performClick(nil); probe.respond(.alertSecondButtonReturn)
        guard window == nil else { throw MailError(message: "Discard did not close the editor") }
        openDraft(draft, sources: sources, accounts: accounts)
        guard title.stringValue == "Recoverable calendar draft" else { throw MailError(message: "Discard overwrote the saved draft") }
        guests.state = .on
        save.performClick(nil)
        await task?.value
        guard window != nil, phase == .ready, save.isEnabled, !status.stringValue.isEmpty else { throw MailError(message: "A failed calendar save left the editor blocked") }
        close()
    }

    private func enableEditing() {
        guard phase == .ready, let key else { return }
        task?.cancel(); generation += 1; let revision = generation
        transition(.authorizing)
        status.stringValue = "Waiting for calendar-write consent in your browser. Existing mail access stays read-only."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.calendarConsent.rawValue, "account": key.account], mode: .live, queue: .login)
                guard generation == revision else { return }
                transition(.ready); onQueued?()
                status.stringValue = "Calendar editing enabled. Save when ready."
            } catch {
                guard generation == revision else { return }
                transition(.ready); status.stringValue = error is CancellationError ? "Sign-in cancelled." : error.localizedDescription
            }
        }
    }
}
