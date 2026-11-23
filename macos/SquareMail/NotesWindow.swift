import AppKit
import ClassicKit

@MainActor
final class NotesWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private enum NoteFocus { case editor, preserve }
    private enum Host { case window, docked }
    private var host = Host.window
    private var exposure = WorkspaceExposure.visible
    private enum Phase { case closed, loading, editing, prompting }
    let shell = WorkspaceWindow(title: "Square Mail - Notes", size: NSSize(width: 1100, height: 760), minimum: NSSize(width: 820, height: 560))
    private let service: NotesService
    private let backup: NotesBackupService
    private let prompts: EditorPrompting
    private let view = NotesCanvas()
    private let editorUndo = UndoManager()
    private static let undoLimit = 50
    private var phase = Phase.closed
    private var notes: [NoteSummary] = []
    private var filtered: [NoteSummary] = []
    private var document: NoteDocument?
    private var directory: URL?
    private var version = 0
    private var savedVersion = 0
    private var generation = 0
    private var restoring = false
    private var saving = false
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var autosave: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var queryRevision = 0
    private var indexPending = 0
    private enum SearchDelay { case immediate, typing }
    private let dayFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    var onClosed: (() -> Void)?
    var onSelect: (() -> Void)?
    var onDock: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var isOpen: Bool { phase != .closed && (host == .docked || shell.isOpen) }
    var isDetached: Bool { host == .window && shell.isOpen }
    var canMove: Bool { phase != .prompting }
    var currentTitle: String { shell.window.title }
    private var activeWindow: NSWindow { view.window ?? shell.window }
    var needsClosePrompt: Bool { isOpen && (dirty || saving) }
    private var dirty: Bool { version != savedVersion }

    init(core: MailCore, backup: NotesBackupService? = nil, prompts: EditorPrompting? = nil) {
        self.backup = backup ?? NotesBackupService(core: core)
        service = NotesService(core: core); self.prompts = prompts ?? EditorPrompter()
        super.init()
        editorUndo.levelsOfUndo = Self.undoLimit
        view.frame = shell.body.bounds; view.autoresizingMask = [.width, .height]; shell.body.addSubview(view)
        view.table.dataSource = self; view.table.delegate = self; view.search.delegate = self; view.text.delegate = self
        view.today.onPress = { [weak self] in self?.openDaily(Date()) }
        view.new.onPress = { [weak self] in self?.newNote() }
        view.save.onPress = { [weak self] in self?.save() }
        view.copy.onPress = { [weak self] in self?.saveCopy() }
        view.reload.onPress = { [weak self] in self?.reload() }
        view.folder.onPress = { [weak self] in
            guard let self, let directory, !WindowPresentation.isBackground else { return }; NSWorkspace.shared.open(directory)
        }
        view.heading.onPress = { [weak self] in self?.insert("# ") }
        view.task.onPress = { [weak self] in self?.insert("- [ ] ") }
        view.backup.onPress = { [weak self] in guard let self else { return }; self.backup.show(note: document?.id) }
        view.dock.onPress = { [weak self] in self?.onDock?() }
        view.link.onPress = { [weak self] in self?.insert("[link](https://)") }
        shell.onCloseRequest = { [weak self] in self?.requestClose() }
        shell.onClosed = { [weak self] in self?.closed() }
        shell.onExposure = { [weak self] state in guard let self, host == .window else { return }; setExposure(state) }
        service.onChange = { [weak self] in self?.externalChange() }
        service.onIndexed = { [weak self] state in
            guard let self else { return }; indexPending = state.pending; updateSearchStatus()
            if !view.search.stringValue.isEmpty { search(.immediate) }
        }
        service.onIndexError = { [weak self] message in self?.view.results.stringValue = "Search index paused"; self?.view.results.toolTip = message + " Reload notes to retry." }
        updateControls()
    }
    func show() {
        if host == .docked { onSelect?(); setExposure(.visible); openIfNeeded(); return }
        attach(to: shell.body); view.dock.isHidden = onDock == nil; shell.show(); setExposure(.visible); openIfNeeded()
    }
    func dock(in container: NSView) {
        guard canMove else { return }; shell.hideForDock(); host = .docked; view.dock.isHidden = true
        attach(to: container); setExposure(.visible); openIfNeeded(); activeWindow.makeFirstResponder(view.text)
    }
    func detach() {
        guard canMove else { return }; host = .window; attach(to: shell.body); show(); activeWindow.makeFirstResponder(view.text)
    }
    func setExposure(_ value: WorkspaceExposure) {
        guard exposure != value else { return }; exposure = value
        if value == .hidden { service.stop(); queryRevision += 1; queryTask?.cancel(); return }
        service.start()
        if phase == .editing { externalChange() }
    }
    private func attach(to container: NSView) {
        if view.superview !== container { view.removeFromSuperview(); container.addSubview(view) }
        view.frame = container.bounds; view.autoresizingMask = [.width, .height]; view.needsLayout = true; view.layoutSubtreeIfNeeded()
    }
    private func setTitle(_ value: String) { shell.setTitle(value); onTitleChanged?(value) }
    private func openIfNeeded() {
        guard phase == .closed else { return }
        service.start()
        phase = .loading; generation += 1; let revision = generation; updateControls()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await refreshList(); try Task.checkCancellation()
                guard revision == generation, isOpen else { return }
                let today = "Daily/" + dayFormat.string(from: Date()) + ".md"
                let id = notes.first(where: { $0.id == today })?.id ?? notes.first?.id
                let note: NoteDocument
                if let id { note = try await service.open(id) } else { note = try await service.create(day: dayFormat.string(from: Date())) }
                guard !Task.isCancelled, revision == generation, isOpen else { return }
                fill(note); try await refreshList()
            } catch { guard revision == generation, isOpen else { return }; phase = .editing; view.status.stringValue = error.localizedDescription; updateControls() }
        }
    }
    func openNote(_ id: String) { show(); switchDocument(id: id) }
    func openDaily(_ date: Date) { show(); switchDocument(day: dayFormat.string(from: date)) }
    func newNote() { show(); switchDocument() }
    func searchAll() { activeWindow.makeFirstResponder(view.search) }
    func refreshNotes() { externalChange() }
    func find() {
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.text.performFindPanelAction(item)
    }
    private func switchDocument(id: String? = nil, day: String? = nil) {
        guard phase != .prompting, !saving else { view.status.stringValue = "Saving the current note. Try again when it finishes."; restoreSelection(); return }
        generation += 1; let revision = generation
        autosave?.cancel(); phase = .loading; updateControls()
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if dirty { try await storeSnapshot() }
                try Task.checkCancellation(); guard generation == revision else { return }
                let note: NoteDocument
                if let id { note = try await service.open(id) } else { note = try await service.create(day: day) }
                guard !Task.isCancelled, generation == revision else { return }
                fill(note); try await refreshList()
            } catch {
                guard generation == revision else { return }
                phase = .editing; view.status.stringValue = error.localizedDescription; restoreSelection(); updateControls()
            }
        }
    }
    private func fill(_ note: NoteDocument, focus: NoteFocus = .editor) {
        document = note; version = 0; savedVersion = 0; phase = .editing
        view.text.string = note.text; view.text.undoManager?.removeAllActions()
        view.status.stringValue = "Markdown · saved locally · " + note.id
        setTitle("Square Mail - " + title(note.text)); restoreSelection(); updateControls()
        if focus == .editor { activeWindow.makeFirstResponder(view.text) }
    }
    private func title(_ text: String) -> String {
        let line = String(text.prefix(4096)).split(separator: "\n").first(where: { $0.hasPrefix("# ") })
        return line.map { String($0.dropFirst(2).prefix(160)) } ?? "Notes"
    }
    private func updateControls() {
        let editing = phase == .editing
        view.text.isEditable = editing
        view.table.isEnabled = editing && !saving
        for button in [view.today, view.new, view.reload, view.copy, view.save] { button.isEnabled = editing && !saving }
        view.save.isEnabled = editing && document != nil && !saving
        view.copy.isEnabled = editing && document != nil && !saving
        view.reload.isEnabled = editing && document != nil && !saving
        for button in [view.heading, view.task, view.link] { button.isEnabled = editing && document != nil }
    }
    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }
    func textDidChange(_ notification: Notification) {
        guard phase == .editing else { return }
        version += 1; setTitle("Square Mail - " + title(view.text.string) + " · Unsaved")
        scheduleSave()
    }
    private func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            self?.save()
        }
    }
    func save() {
        guard phase == .editing, !saving, document != nil else { return }
        autosave?.cancel(); saving = true; updateControls(); view.status.stringValue = "Saving on this Mac…"
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saving = false; updateControls() }
            do {
                try await storeSnapshot()
                view.status.stringValue = dirty ? "Newer edits are waiting to save." : "Saved on this Mac."
                if !dirty { setTitle("Square Mail - " + title(view.text.string)) }
                try await refreshList()
                if dirty { scheduleSave() }
            } catch { view.status.stringValue = error.localizedDescription }
        }
    }
    private func storeSnapshot() async throws {
        guard var note = document else { return }
        let saved = version; let revision = generation
        note.text = view.text.string
        let value = try await service.save(note)
        guard generation == revision else { return }
        document = value; savedVersion = saved; backup.requestSync()
    }
    private func saveCopy() {
        guard phase == .editing, !saving else { return }
        let text = view.text.string
        generation += 1; let revision = generation
        phase = .loading; autosave?.cancel(); updateControls()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var copy = try await service.create(); copy.text = text
                let saved = try await service.save(copy)
                guard !Task.isCancelled, revision == generation, isOpen else { return }
                fill(saved); try await refreshList(); view.status.stringValue = "Saved a separate copy. The original file was not changed."
            } catch { guard revision == generation, isOpen else { return }; phase = .editing; view.status.stringValue = error.localizedDescription; updateControls() }
        }
    }
    private func reload() {
        guard let document else { return }
        if dirty {
            let alert = NSAlert(); alert.messageText = "Reload this note from disk?"; alert.informativeText = "Unsaved editor changes will be discarded. Save a copy first to keep them."
            alert.addButton(withTitle: "Reload"); alert.addButton(withTitle: "Keep editing")
            phase = .prompting; autosave?.cancel(); updateControls()
            prompts.choose(alert, window: activeWindow) { [weak self] response in
                guard let self else { return }; phase = .editing; updateControls()
                if response == .alertFirstButtonReturn { version = savedVersion; switchDocument(id: document.id) }
            }
        } else { switchDocument(id: document.id) }
    }
    func requestClose(_ reply: @escaping (CalendarEditor.CloseOutcome) -> Void = { _ in }) {
        guard phase != .prompting else { reply(.cancelled); return }
        if saving {
            Task { [weak self] in await self?.saveTask?.value; self?.requestClose(reply) }; return
        }
        task?.cancel(); generation += 1
        guard dirty else { finishClosing(); reply(.closed); return }
        let alert = NSAlert(); alert.messageText = "Save this note?"; alert.informativeText = "Save on this Mac, discard unsaved editor changes, or keep editing."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard changes"); alert.addButton(withTitle: "Keep editing")
        phase = .prompting; autosave?.cancel(); updateControls()
        prompts.choose(alert, window: activeWindow) { [weak self] response in
            guard let self else { reply(.cancelled); return }
            phase = .editing; updateControls()
            if response == .alertSecondButtonReturn { finishClosing(); reply(.closed); return }
            guard response == .alertFirstButtonReturn else { reply(.cancelled); return }
            save()
            Task { [weak self] in
                await self?.saveTask?.value
                guard let self, !dirty else { reply(.cancelled); return }
                finishClosing(); reply(.closed)
            }
        }
    }
    func close() { finishClosing() }
    private func finishClosing() {
        if host == .window { shell.close() } else { view.removeFromSuperview(); closed() }
    }
    private func closed() {
        phase = .closed; generation += 1; queryRevision += 1
        for job in [task, saveTask, listTask, autosave, queryTask] { job?.cancel() }
        service.stop(); editorUndo.removeAllActions(); view.text.string = ""; document = nil; notes.removeAll(); filtered.removeAll(); onClosed?()
    }
    private func externalChange() {
        guard isOpen, exposure == .visible, phase == .editing, !saving else { return }
        listTask?.cancel(); let revision = generation
        listTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await refreshList()
                if let document, !dirty {
                    let disk = try await service.open(document.id)
                    if !Task.isCancelled, revision == generation, isOpen, !dirty, phase == .editing, self.document?.id == disk.id, document.revision != disk.revision { fill(disk, focus: .preserve) }
                } else if revision == generation, isOpen, dirty { view.status.stringValue = "External folder change. Saving checks this file before replacing it." }
            } catch { view.status.stringValue = error.localizedDescription }
        }
    }
    private func refreshList() async throws {
        let value = try await service.list(); try Task.checkCancellation()
        notes = value.notes; directory = URL(fileURLWithPath: value.directory); indexPending = value.pending; filter(); search(.immediate)
    }
    func controlTextDidChange(_ notification: Notification) { filter(); search(.typing) }
    private func filter() {
        let query = view.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = notes.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
        reloadResults()
    }
    private func reloadResults() {
        restoring = true; view.table.reloadData(); restoring = false; restoreSelection(); updateSearchStatus()
    }
    private func updateSearchStatus() {
        let searching = !view.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let label = searching ? "\(filtered.count) results" : "\(notes.count) notes"
        view.results.stringValue = indexPending > 0 ? label + " · indexing \(indexPending)" : label
        view.results.toolTip = indexPending > 0 ? "Search includes each note as its local index becomes ready." : "Search titles, filenames and full Markdown content on this Mac."
    }
    private func search(_ delay: SearchDelay) {
        queryTask?.cancel(); queryRevision += 1; let revision = queryRevision
        let query = view.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, isOpen, exposure == .visible else { return }
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay == .typing { try await Task.sleep(for: .milliseconds(120)) }
                let found = try await service.search(query)
                guard !Task.isCancelled, revision == queryRevision, isOpen, exposure == .visible, view.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                filtered = found.notes; indexPending = found.pending; reloadResults()
            } catch { if !Task.isCancelled, revision == queryRevision { view.results.stringValue = "Search unavailable"; view.results.toolTip = error.localizedDescription } }
        }
    }
    private func restoreSelection() {
        restoring = true
        if let id = document?.id, let index = filtered.firstIndex(where: { $0.id == id }) { view.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { view.table.deselectAll(nil) }
        restoring = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("note-row")
        let view = tableView.makeView(withIdentifier: id, owner: self) as? ClassicRow ?? ClassicRow(); view.identifier = id; return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell ?? ClassicTableCell(); cell.identifier = id
        cell.configure(filtered[row].title + (filtered[row].available ? "" : " · unavailable")); cell.toolTip = filtered[row].id; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring, filtered.indices.contains(view.table.selectedRow) else { return }
        let id = filtered[view.table.selectedRow].id; if document?.id != id { switchDocument(id: id) }
    }
    private func insert(_ value: String) { activeWindow.makeFirstResponder(view.text); view.text.insertText(value, replacementRange: view.text.selectedRange()) }
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if textView.string.utf16.count - range.length + (replacementString?.utf16.count ?? 0) <= 1024 * 1024 { return true }
        view.status.stringValue = "Note limit is 1 MiB. Original files were not changed."; return false
    }
}

private final class NotesCanvas: NSView {
    let table = NSTableView(); let search = NSTextField(); let text = NSTextView(usingTextLayoutManager: false)
    let today = ClassicButton("Today"); let new = ClassicButton("New note"); let save = ClassicButton("Save")
    let copy = ClassicButton("Save copy"); let reload = ClassicButton("Reload"); let folder = ClassicButton("Open folder")
    let backup = ClassicButton("Encrypted backup…")
    let dock = ClassicButton("Dock to tabs")
    let heading = ClassicButton("Heading"); let task = ClassicButton("Checkbox"); let link = ClassicButton("Link")
    let results = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "Loading local Markdown notes…")
    private let list = NSScrollView(); private let editor = NSScrollView(); private let actions = ClassicActionBar()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note")); column.width = 215; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 30; table.style = .plain; table.setAccessibilityLabel("Local Markdown notes")
        list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        editor.documentView = text; editor.hasVerticalScroller = true; editor.borderType = .bezelBorder
        text.isRichText = false; text.allowsUndo = true; text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular); text.textColor = ClassicTheme.ink; text.backgroundColor = .white
        text.textContainerInset = NSSize(width: 16, height: 12); text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); text.textContainer?.widthTracksTextView = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false
        text.setAccessibilityLabel("Markdown note editor")
        search.placeholderString = "Search all notes"; search.font = ClassicTheme.font(11); search.setAccessibilityLabel("Search note titles and full content")
        results.font = ClassicTheme.font(10); results.textColor = ClassicTheme.muted; results.lineBreakMode = .byTruncatingTail
        status.font = ClassicTheme.font(10); status.textColor = ClassicTheme.ink; status.lineBreakMode = .byTruncatingTail
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        for button in [today, new, save, copy, reload, folder, backup, dock, heading, task, link] { actions.addItem(button, width: button === backup ? 150 : button === dock ? 110 : button === folder ? 100 : 85, priority: [today, new, save].contains(button) ? .primary : .secondary) }
        today.toolTip = "Open or create today's Markdown note."; new.toolTip = "Create a free note."; save.toolTip = "Save on this Mac (⌘S)."
        copy.toolTip = "Save editor text as another file, keeping the original."; reload.toolTip = "Reload the file from disk, with a discard prompt for unsaved edits."
        folder.toolTip = "Open the Markdown folder in Finder. It can also be opened by Obsidian or another text editor."
        for child in [list, editor, actions, search, results, status] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout(); let side: CGFloat = 230; let toolbar = actions.fittingHeight(bounds.width - side - 4)
        search.frame = NSRect(x: 6, y: 6, width: side - 12, height: 26)
        list.frame = NSRect(x: 4, y: 40, width: side - 8, height: max(0, bounds.height - 94))
        results.frame = NSRect(x: 8, y: bounds.height - 49, width: side - 16, height: 18)
        actions.frame = NSRect(x: side, y: 0, width: bounds.width - side, height: toolbar)
        editor.frame = NSRect(x: side + 4, y: toolbar + 4, width: max(0, bounds.width - side - 8), height: max(0, bounds.height - toolbar - 38))
        text.setFrameSize(NSSize(width: editor.contentSize.width, height: max(editor.contentSize.height, text.frame.height)))
        status.frame = NSRect(x: 8, y: bounds.height - 27, width: bounds.width - 16, height: 22)
    }
}

extension NotesWindow {
    func verifyControls(_ prompts: ScriptedEditorPrompts) async throws {
        guard WindowPresentation.isBackground else { throw MailError(message: "Use a hidden notes fixture") }
        show(); await task?.value
        guard phase == .editing, let original = document, original.id.hasPrefix("Daily/"), view.text.isEditable else { throw MailError(message: "Notes did not lazily open a local daily file") }
        view.text.string = "# Renamed daily title\n\n- [ ] First task\n\n[Example](https://example.test)\n"
        textDidChange(Notification(name: NSText.didChangeNotification)); let editor = shell.window.firstResponder
        save(); guard view.text.isEditable, shell.window.firstResponder === editor else { throw MailError(message: "Note autosave blocked typing or stole focus") }
        await saveTask?.value
        guard !dirty, let saved = document, saved.text == view.text.string, saved.id == original.id else { throw MailError(message: "Note save lost text or its stable date identity") }
        var external = saved; external.text = "# External editor\nKeep this text\n"; _ = try await service.save(external)
        view.text.string = "# My unsaved editor\nKeep these edits too\n"; textDidChange(Notification(name: NSText.didChangeNotification)); save(); await saveTask?.value
        guard dirty, view.text.string.contains("My unsaved"), view.status.stringValue.localizedStandardContains("change") else { throw MailError(message: "External edit was silently overwritten") }
        view.copy.performClick(nil); await task?.value
        guard let copied = document, copied.id != original.id, copied.text.contains("My unsaved"), !dirty,
              try await service.open(original.id).text == external.text else { throw MailError(message: "Save copy lost either side of a note conflict") }
        try WindowPresentation.snapshot(shell.window.contentView!, name: "notes-editor")
        view.text.insertText("New edit", replacementRange: view.text.selectedRange())
        guard dirty, view.text.undoManager?.canUndo == true else { throw MailError(message: "Notes lost native text Undo or autosave edits") }
        shell.window.performClose(nil)
        guard prompts.pending, phase == .prompting else { throw MailError(message: "Notes close skipped its unsaved prompt") }
        prompts.respond(.alertThirdButtonReturn)
        guard shell.isOpen, phase == .editing, dirty else { throw MailError(message: "Keep editing lost the note") }
        shell.window.performClose(nil); prompts.respond(.alertFirstButtonReturn); await saveTask?.value
        for _ in 0..<20 where shell.isOpen { try await Task.sleep(for: .milliseconds(5)) }
        guard !shell.isOpen else { throw MailError(message: "Saved notes did not close") }
        show(); shell.window.performClose(nil); await task?.value
        guard phase == .closed, document == nil, !shell.isOpen else { throw MailError(message: "A late note load reopened a closed editor") }
    }
}


extension NotesWindow {
    func verifyFullSearch() async throws {
        guard WindowPresentation.isBackground else { throw MailError(message: "Use the hidden search fixture") }
        show(); await task?.value
        var note = try await service.create(); note.text = "# Unrelated title\n" + String(repeating: "ordinary paragraph ", count: 400) + "\nbodyonlyneedle"
        let saved = try await service.save(note); try await refreshList()
        view.search.stringValue = "bodyonlyneedle"; controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification))
        for _ in 0..<200 {
            if filtered.contains(where: { $0.id == saved.id }) { break }; try await Task.sleep(for: .milliseconds(20))
        }
        guard filtered.count == 1, filtered[0].id == saved.id else { throw MailError(message: "Full-note search did not find text beyond the title preview") }
        view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); await task?.value
        guard document?.id == saved.id, view.text.string == saved.text else { throw MailError(message: "Body search opened another note") }
        view.search.stringValue = "externallychangedneedle"; controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification)); await queryTask?.value
        guard let directory else { throw MailError(message: "Missing fixture folder") }
        try Data("# Unrelated title\nexternallychangedneedle".utf8).write(to: directory.appendingPathComponent(saved.id))
        for _ in 0..<200 {
            if filtered.contains(where: { $0.id == saved.id }) && view.text.string.contains("externallychangedneedle") { break }; try await Task.sleep(for: .milliseconds(20))
        }
        guard filtered.count == 1, filtered[0].id == saved.id, view.text.string.contains("externallychangedneedle") else { throw MailError(message: "In-place external editing did not refresh the editor and search index") }
        view.search.stringValue = "bodyonlyneedle"; controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification)); await queryTask?.value
        guard filtered.isEmpty else { throw MailError(message: "Search retained old body terms") }
        view.search.stringValue = ""; controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification))
        guard filtered.count == notes.count else { throw MailError(message: "Clearing note search lost the list") }
        try WindowPresentation.snapshot(shell.window.contentView!, name: "notes-full-search")
        close()
    }
    func verifyTransfers(detach: () -> Void, dock: () -> Void, hide: () -> Void, show: () -> Void) async throws {
        guard WindowPresentation.isBackground else { throw MailError(message: "Use the hidden tab fixture") }
        await task?.value; guard host == .docked, let note = document else { throw MailError(message: "Notes did not open inside its tab") }
        let editor = view.text
        view.text.insertText("Tab transfer edits", replacementRange: view.text.selectedRange())
        let text = view.text.string; let range = view.text.selectedRange(); let undo = view.text.undoManager
        guard dirty, undo?.canUndo == true else { throw MailError(message: "The tab editor lost text Undo") }
        detach()
        guard isDetached, view.text === editor, document?.id == note.id, view.text.string == text, view.text.selectedRange() == range, view.text.undoManager === undo, undo?.canUndo == true, activeWindow.firstResponder === editor else { throw MailError(message: "Popout lost the note buffer, selection, Undo or responder") }
        try WindowPresentation.snapshot(shell.window.contentView!, name: "notes-window")
        dock()
        guard host == .docked, !shell.isOpen, view.text === editor, document?.id == note.id, dirty, view.text.undoManager === undo, activeWindow.firstResponder === editor else { throw MailError(message: "Docking lost the editor or left its old window open") }
        guard editor.tryToPerform(NSSelectorFromString("undo:"), with: nil), view.text.string != text else { throw MailError(message: "Undo after docking did not reach the note editor") }
        undo?.redo()
        guard view.text.string == text else { throw MailError(message: "Redo after docking lost the edited text") }
        hide(); guard isOpen, dirty, exposure == .hidden else { throw MailError(message: "Switching tabs discarded pending note edits") }
        show(); await listTask?.value
        guard document?.id == note.id, view.text.string == text, view.text.undoManager === undo else { throw MailError(message: "Tab return replaced the note buffer") }
        save(); await saveTask?.value; guard !dirty else { throw MailError(message: "Moved note could not save offline") }
        if let root = view.window?.contentView { try WindowPresentation.snapshot(root, name: "workspace-notes-tab") }
        close()
    }
}
