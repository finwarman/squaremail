import AppKit
import ClassicKit

@MainActor
final class NotesBackupPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum SetupMode { case create, restore }
    private weak var service: NotesBackupService?
    private let shell = WorkspaceWindow(title: "Square Mail - Encrypted Notes backup", size: NSSize(width: 800, height: 640), minimum: NSSize(width: 740, height: 600))
    private let canvas = BackupCanvas()
    private var mode = SetupMode.create
    private var task: Task<Void, Never>?
    private var invitationTask: Task<Void, Never>?
    private var generation = 0
    private var working = false
    private var noteID: String?
    private var versions: [BackupVersion] = []
    private let dateFormat: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    var onClosed: (() -> Void)?
    init(service: NotesBackupService) {
        self.service = service; super.init()
        canvas.frame = shell.body.bounds; canvas.autoresizingMask = [.width, .height]; shell.body.addSubview(canvas)
        for field in [canvas.invite, canvas.account, canvas.password, canvas.confirm] { field.delegate = self }
        canvas.create.onPress = { [weak self] in self?.mode = .create; self?.refresh() }
        canvas.restore.onPress = { [weak self] in self?.mode = .restore; self?.refresh() }
        canvas.primary.onPress = { [weak self] in self?.submit() }
        canvas.saved.target = self; canvas.saved.action = #selector(changed)
        canvas.copy.onPress = { [weak self] in self?.copyRecovery() }
        canvas.recovery.onPress = { [weak self] in self?.loadRecovery() }
        canvas.sync.onPress = { [weak self] in self?.service?.requestSync() }
        canvas.lock.onPress = { [weak self] in self?.operation(.lock) }
        canvas.disconnect.onPress = { [weak self] in self?.disconnect() }
        canvas.history.onPress = { [weak self] in self?.loadHistory() }
        canvas.restoreVersion.onPress = { [weak self] in self?.restoreVersion() }
        canvas.table.dataSource = self; canvas.table.delegate = self
        shell.onClosed = { [weak self] in
            guard let self else { return }; generation += 1; task?.cancel(); invitationTask?.cancel(); canvas.password.stringValue = ""; canvas.confirm.stringValue = ""; canvas.invite.stringValue = ""; canvas.account.stringValue = ""; canvas.key.stringValue = ""; onClosed?()
        }
        refresh()
    }
    func show(note: String?) {
        if noteID != note { noteID = note; versions.removeAll(); canvas.table.reloadData() }
        shell.show(); refresh()
        guard service?.status.phase == .disabled || service?.status.phase == .setup else { return }
        invitationTask?.cancel(); let revision = generation
        invitationTask = Task { [weak self] in
            guard let self, let service else { return }
            do {
                let value = try await service.invitation()
                guard !Task.isCancelled, revision == generation, shell.isOpen else { return }
                if canvas.invite.stringValue.isEmpty { canvas.invite.stringValue = value.code ?? "" }; refresh()
            } catch { if !Task.isCancelled, revision == generation, shell.isOpen { canvas.detail.stringValue = error.localizedDescription } }
        }
    }
    func close() { shell.close() }
    func refresh() {
        guard let service else { return }
        let status = service.status
        let setup = status.phase == .disabled || status.phase == .setup
        let recovery = status.phase == .recovery
        let unlock = status.phase == .locked || (recovery && !status.unlocked)
        canvas.create.state = mode == .create ? .on : .off; canvas.restore.state = mode == .restore ? .on : .off
        canvas.create.isHidden = !setup; canvas.restore.isHidden = !setup; canvas.restore.isEnabled = !working && status.phase != .setup
        canvas.create.isEnabled = !working
        var rows: [(String, NSControl)] = []
        if setup {
            if mode == .create { rows.append(("Invitation", canvas.invite)) } else { rows.append(("Account key", canvas.account)) }
            rows.append(("Vault passphrase", canvas.password))
            if mode == .create { rows.append(("Confirm passphrase", canvas.confirm)) }
            rows.append(("", canvas.remember))
        } else if unlock { rows = [("Vault passphrase", canvas.password), ("", canvas.remember)] }
        if recovery || !canvas.key.stringValue.isEmpty { rows.append(("Recovery account key", canvas.key)) }
        canvas.setRows(rows)
        canvas.primary.isHidden = !(setup || recovery || unlock)
        canvas.primary.title = setup ? (mode == .create ? "Create encrypted backup" : "Restore backup account") : unlock ? "Unlock backup" : "Enable encrypted backup"
        let validPass = canvas.password.stringValue.utf8.count >= 12 && canvas.password.stringValue.utf8.count <= 1024
        let validCreate = !canvas.invite.stringValue.isEmpty && validPass && canvas.password.stringValue == canvas.confirm.stringValue
        let validRestore = !canvas.account.stringValue.isEmpty && validPass
        canvas.primary.isEnabled = !working && (setup ? (mode == .create ? validCreate : validRestore) : unlock ? validPass : canvas.saved.state == .on)
        canvas.saved.isHidden = !recovery || unlock; canvas.saved.isEnabled = !working
        canvas.copy.isHidden = canvas.key.stringValue.isEmpty; canvas.copy.isEnabled = !working
        canvas.recovery.isHidden = setup; canvas.recovery.isEnabled = !working
        for field in [canvas.invite, canvas.account, canvas.password, canvas.confirm] { field.isEnabled = !working }
        canvas.remember.isEnabled = !working
        canvas.sync.isHidden = status.phase != .ready && status.phase != .busy; canvas.sync.isEnabled = !working
        canvas.lock.isHidden = !status.unlocked || setup; canvas.lock.isEnabled = !working
        canvas.disconnect.isHidden = status.phase == .disabled; canvas.disconnect.isEnabled = !working
        canvas.history.isEnabled = !working && status.phase == .ready && noteID != nil
        canvas.restoreVersion.isEnabled = !working && versions.indices.contains(canvas.table.selectedRow)
        canvas.history.isHidden = status.phase != .ready || noteID == nil
        canvas.restoreVersion.isHidden = canvas.history.isHidden || versions.isEmpty
        canvas.updateHistory(versions)
        canvas.detail.stringValue = working ? "Working… You can keep editing notes in their window." : service.message
        canvas.history.title = noteID == nil ? "Select a note for history" : "Load this note’s history"
        canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
    }
    @objc private func changed() { refresh() }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    private func run(_ body: @escaping () async throws -> Void) {
        guard !working else { return }; invitationTask?.cancel(); working = true; refresh(); let revision = generation
        task = Task { [weak self] in
            var failure: String?
            do { try await body() }
            catch { failure = error.localizedDescription }
            guard let self, !Task.isCancelled, revision == generation, shell.isOpen else { return }
            if !Task.isCancelled { await service?.refresh() }
            guard !Task.isCancelled, revision == generation, shell.isOpen else { return }
            working = false; refresh()
            if let failure { canvas.detail.stringValue = failure }
        }
    }
    private func submit() {
        guard let service else { return }
        if WindowPresentation.isBackground { canvas.detail.stringValue = "Setup is disabled in hidden fixtures."; return }
        let status = service.status
        let fields: [String: Any] = ["password": canvas.password.stringValue, "remember": canvas.remember.state == .on]
        if status.phase == .disabled || status.phase == .setup {
            if mode == .create {
                var values = fields; values["invite"] = canvas.invite.stringValue
                run { [weak self] in
                    let result: BackupCreated = try await service.create(fields: values)
                    guard let self, !Task.isCancelled else { return }
                    canvas.key.stringValue = result.accountKey; canvas.password.stringValue = ""; canvas.confirm.stringValue = ""; canvas.invite.stringValue = ""; service.accept(result.status)
                }
            } else {
                var values = fields; values["account_key"] = canvas.account.stringValue
                run { [weak self] in
                    let value: BackupStatus = try await service.change(.connect, fields: values)
                    guard let self, !Task.isCancelled else { return }
                    canvas.password.stringValue = ""; canvas.key.stringValue = canvas.account.stringValue; canvas.account.stringValue = ""; service.accept(value)
                }
            }
            return
        }
        if status.phase == .locked || !status.unlocked { operation(.unlock, fields: fields); return }
        guard canvas.saved.state == .on else { return }; operation(.enable)
    }
    private func operation(_ action: BackupOperation, fields: [String: Any] = [:]) {
        guard let service else { return }
        run { [weak self] in
            let value: BackupStatus = try await service.change(action, fields: fields)
            guard let self, !Task.isCancelled else { return }; canvas.password.stringValue = ""; service.accept(value)
        }
    }
    private func loadRecovery() {
        guard let service else { return }
        run { [weak self] in let value: BackupRecovery = try await service.recovery(); guard !Task.isCancelled else { return }; self?.canvas.key.stringValue = value.accountKey; await service.refresh() }
    }
    private func copyRecovery() {
        guard !canvas.key.stringValue.isEmpty, !WindowPresentation.isBackground else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(canvas.key.stringValue, forType: .string)
        canvas.detail.stringValue = "Account key copied. Save it in 1Password alongside your vault passphrase."
    }
    private func disconnect() {
        let alert = NSAlert(); alert.messageText = "Disconnect encrypted backup?"; alert.informativeText = "Local notes and encrypted server versions stay in place. This Mac forgets its backup credentials."
        alert.addButton(withTitle: "Disconnect"); alert.addButton(withTitle: "Keep connected")
        if WindowPresentation.runAlert(alert) == .alertFirstButtonReturn { canvas.key.stringValue = ""; operation(.disconnect) }
    }
    private func loadHistory() {
        guard let service, let noteID else { return }
        run { [weak self] in
            let history: BackupHistory = try await service.history(noteID)
            guard let self, !Task.isCancelled else { return }; versions = history.items; canvas.table.reloadData(); canvas.detail.stringValue = versions.isEmpty ? "No older versions for this note yet." : "Choose a version to restore as a separate note."; await service.refresh()
        }
    }
    private func restoreVersion() {
        guard let service, let noteID, versions.indices.contains(canvas.table.selectedRow) else { return }
        let revision = versions[canvas.table.selectedRow].revision
        run {
            let note: NoteDocument = try await service.restore(noteID, revision: revision)
            guard !Task.isCancelled else { return }; service.restored(note); await service.refresh()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard versions.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell ?? ClassicTableCell(); cell.identifier = id
        cell.configure(dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(versions[row].created)))); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }
}

private final class BackupCanvas: NSView {
    let create = ClassicButton("Create backup", style: .segment); let restore = ClassicButton("Restore account", style: .segment)
    let invite = NSSecureTextField(); let account = NSSecureTextField(); let password = NSSecureTextField(); let confirm = NSSecureTextField(); let key = NSSecureTextField()
    let remember = ClassicCheckbox("Remember this device in Keychain")
    let saved = ClassicCheckbox("I saved my account key and vault passphrase in my password manager")
    let primary = ClassicButton("Create encrypted backup"); let copy = ClassicButton("Copy account key"); let recovery = ClassicButton("Show recovery key")
    let sync = ClassicButton("Sync now"); let lock = ClassicButton("Lock backup"); let disconnect = ClassicButton("Disconnect")
    let history = ClassicButton("Select a note for history"); let restoreVersion = ClassicButton("Restore as copy")
    let table = NSTableView(); let detail = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(wrappingLabelWithString: "Encrypted Notes backup · f1nb0.dev\nYour vault passphrase stays on this Mac. Notes remain usable offline.")
    private let help = NSTextField(wrappingLabelWithString: "Save both the account key and vault passphrase in 1Password. A new Mac needs both. Local Markdown files stay ordinary files; uploaded copies are encrypted. Encrypted storage allowance: 32 MiB and 2,000 notes. Older versions use a separate 8 MiB budget, up to 50 entries.")
    private let scroll = NSScrollView()
    private var labels: [NSTextField] = []
    private var rows: [(String, NSControl)] = []
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        key.isEditable = false; key.isSelectable = true; remember.state = .on
        for field in [invite, account, password, confirm, key] { field.font = ClassicTheme.font(12); field.textColor = ClassicTheme.ink; field.backgroundColor = .white; addSubview(field) }
        invite.placeholderString = "Private preview invitation"; account.placeholderString = "Account key from your password manager"; password.placeholderString = "At least 12 characters"; confirm.placeholderString = "Enter the same vault passphrase"
        for (field, title) in [(invite,"Backup invitation"), (account,"Backup account key"), (password,"Vault passphrase"), (confirm,"Confirm vault passphrase"), (key,"Recovery account key")] { field.setAccessibilityLabel(title) }
        heading.font = ClassicTheme.font(12, weight: .bold); help.font = ClassicTheme.font(10); detail.font = ClassicTheme.font(11)
        for label in [heading, help, detail] { label.textColor = ClassicTheme.ink }
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))); table.headerView = nil; table.rowHeight = 26; table.style = .plain
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        for view in [heading, help, detail, create, restore, remember, saved, primary, copy, recovery, sync, lock, disconnect, history, restoreVersion, scroll] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func setRows(_ values: [(String, NSControl)]) {
        rows = values
        for field in [invite, account, password, confirm, key, remember] { field.isHidden = !values.contains(where: { $0.1 === field }) }
        while labels.count < values.count { let label = NSTextField(labelWithString: ""); label.font = ClassicTheme.font(11); label.textColor = ClassicTheme.ink; addSubview(label); labels.append(label) }
        for (index, label) in labels.enumerated() { label.isHidden = index >= values.count; if values.indices.contains(index) { label.stringValue = values[index].0 } }
    }
    func updateHistory(_ versions: [BackupVersion]) { scroll.isHidden = history.isHidden || versions.isEmpty }
    override func layout() {
        super.layout(); let width = bounds.width
        heading.frame = NSRect(x: 16, y: 10, width: width - 32, height: 48)
        create.frame = NSRect(x: 16, y: 66, width: 150, height: 28); restore.frame = NSRect(x: 166, y: 66, width: 150, height: 28)
        var y: CGFloat = create.isHidden ? 68 : 108
        for (index, row) in rows.enumerated() { labels[index].frame = NSRect(x: 16, y: y + 5, width: 160, height: 22); row.1.frame = NSRect(x: 184, y: y, width: width - 200, height: 28); y += 40 }
        copy.frame = NSRect(x: width - 170, y: y, width: 154, height: 28)
        if !copy.isHidden { y += 36 }
        saved.frame = NSRect(x: 16, y: y, width: width - 32, height: 26)
        if !saved.isHidden { y += 34 }
        primary.frame = NSRect(x: 16, y: y, width: 230, height: 30)
        if !primary.isHidden { y += 40 }
        var x: CGFloat = 16
        for button in [sync, lock, recovery, disconnect] where !button.isHidden { button.frame = NSRect(x: x, y: y, width: button === recovery ? 158 : 120, height: 28); x += button.frame.width + 8 }
        if x > 16 { y += 40 }
        history.frame = NSRect(x: 16, y: y, width: 220, height: 28); restoreVersion.frame = NSRect(x: 246, y: y, width: 150, height: 28)
        if !history.isHidden { y += 36 }
        scroll.frame = NSRect(x: 16, y: y, width: width - 32, height: max(40, min(120, bounds.height - y - 144)))
        detail.frame = NSRect(x: 16, y: bounds.height - 98, width: width - 32, height: 40)
        help.frame = NSRect(x: 16, y: bounds.height - 54, width: width - 32, height: 50)
    }
}

extension NotesBackupPanel {
    func verifyControls() async throws {
        guard WindowPresentation.isBackground, let service else { throw MailError(message: "Use the hidden backup fixture") }
        await service.refresh(); show(note: nil)
        guard service.status.phase == .disabled, !canvas.primary.isEnabled else { throw MailError(message: "Unconfigured backup did not remain local-only") }
        canvas.invite.stringValue = String(repeating: "a", count: 43); canvas.password.stringValue = "synthetic-only-passphrase"; canvas.confirm.stringValue = "different-passphrase"; refresh()
        guard !canvas.primary.isEnabled else { throw MailError(message: "Backup accepted mismatched passphrases") }
        canvas.confirm.stringValue = canvas.password.stringValue; refresh()
        guard canvas.primary.isEnabled else { throw MailError(message: "Matching backup setup did not enable its action") }
        canvas.primary.performClick(nil)
        guard !working, service.status.phase == .disabled, canvas.detail.stringValue.contains("hidden fixtures") else { throw MailError(message: "Hidden backup setup crossed the live boundary") }
        try WindowPresentation.snapshot(shell.window.contentView!, name: "backup-setup")
        canvas.restore.performClick(nil)
        guard mode == .restore, canvas.restore.state == .on, canvas.create.state == .off, !canvas.primary.isEnabled else { throw MailError(message: "Backup setup modes retained stale button state") }
        service.accept(BackupStatus(phase: .recovery, unlocked: true, account: "fixture", completed: 0, more: false, message: "Save the recovery credential before uploading."))
        canvas.key.stringValue = "synthetic-recovery-account"; refresh()
        guard !canvas.primary.isEnabled, !canvas.saved.isHidden else { throw MailError(message: "Backup skipped recovery confirmation") }
        canvas.saved.state = .on; changed()
        guard canvas.primary.isEnabled else { throw MailError(message: "Recovery confirmation did not enable backup") }
        try WindowPresentation.snapshot(shell.window.contentView!, name: "backup-recovery")
        shell.window.performClose(nil)
        guard canvas.password.stringValue.isEmpty, canvas.key.stringValue.isEmpty else { throw MailError(message: "Closed backup panel retained visible secrets") }
        await service.refresh()
    }
}
