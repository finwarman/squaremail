import AppKit
import ClassicKit

@MainActor
final class MailWorkspacePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private enum Row { case draft(DraftSummary), work(MailWorkSummary) }
    private let core: MailCore
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let account = NSPopUpButton(frame: .zero)
    private let changes = ClassicButton("Enable mail changes…")
    private let sending = ClassicButton("Enable sending…")
    private let openButton = ClassicButton("Open draft")
    private let remove = ClassicButton("Delete draft")
    private let retry = ClassicButton("Retry")
    private let cancel = ClassicButton("Cancel queued")
    private let recover = ClassicButton("Resolve stopped…")
    private let refreshButton = ClassicButton("Refresh")
    private let status = NSTextField(wrappingLabelWithString: "Local drafts, queued changes and sends. Nothing is permanently deleted at the provider.")
    private var rows: [Row] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var opened = false
    private var busy = false
    private var authorizing = false
    var onOpen: ((String) -> Void)?
    var onChange: (() -> Void)?
    var onConsent: ((String, MailAccess) -> Void)?
    init(core: MailCore) {
        self.core = core; super.init()
        window.title = "Mail drafts / outbox"; window.isReleasedWhenClosed = false; window.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 125, width: 760, height: 335)); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mail-work")); column.width = 740; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 46; table.style = .plain; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Local mail drafts and queued work")
        window.contentView?.addSubview(scroll)
        for (index, button) in [openButton, remove, retry, cancel, recover, refreshButton].enumerated() {
            button.frame = NSRect(x: 10 + index * 126, y: 91, width: 120, height: 27); window.contentView?.addSubview(button)
        }
        account.frame = NSRect(x: 10, y: 56, width: 315, height: 26)
        changes.frame = NSRect(x: 335, y: 56, width: 210, height: 27); sending.frame = NSRect(x: 555, y: 56, width: 210, height: 27)
        status.frame = NSRect(x: 10, y: 5, width: 755, height: 44); status.font = ClassicTheme.font(10)
        for view in [account, changes, sending, status] { window.contentView?.addSubview(view) }
        openButton.onPress = { [weak self] in self?.openSelected() }
        remove.onPress = { [weak self] in self?.deleteDraft() }
        refreshButton.onPress = { [weak self] in self?.refresh() }
        retry.onPress = { [weak self] in self?.work(.retry) }; cancel.onPress = { [weak self] in self?.work(.cancel) }; recover.onPress = { [weak self] in self?.work(.forget) }
        changes.onPress = { [weak self] in self?.consent(.changes) }; sending.onPress = { [weak self] in self?.consent(.send) }
        updateButtons()
    }
    func open(accounts: [Account]) {
        account.removeAllItems()
        for value in accounts where value.provider != .local { account.addItem(withTitle: value.email); account.lastItem?.representedObject = value.id }
        opened = true; window.center(); WindowPresentation.show(window); refresh()
    }
    func close() { opened = false; generation += 1; task?.cancel(); task = nil; window.close() }
    func windowWillClose(_ notification: Notification) { opened = false; generation += 1; task?.cancel(); task = nil }
    func setAuthorizing(_ value: CommandPhase) { authorizing = value == .busy; updateButtons() }
    enum CommandPhase { case ready, busy }
    func showStatus(_ value: String) { status.stringValue = value }
    func refresh() {
        guard opened, !busy else { return }
        generation += 1; let revision = generation; task?.cancel(); busy = true; updateButtons()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let values: MailWorkspace = try await core.request(["command": CoreCommand.mailWorkspace.rawValue], mode: .live)
                guard generation == revision else { return }
                rows = values.drafts.map(Row.draft) + values.work.map(Row.work); table.deselectAll(nil); table.reloadData()
                busy = false; updateButtons()
                status.stringValue = "\(values.drafts.count)/100 local drafts · \(values.work.count) queued/stopped operations · 50 sends, 100 actions max"
            } catch { guard generation == revision else { return }; busy = false; updateButtons(); status.stringValue = error.localizedDescription }
        }
    }
    private var selection: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func updateButtons() {
        let ready = !busy
        let draft: Bool; let work: MailWorkSummary?
        switch selection { case .draft: draft = true; work = nil; case .work(let value): draft = false; work = value; default: draft = false; work = nil }
        openButton.isEnabled = ready && draft; remove.isEnabled = ready && draft
        retry.isEnabled = ready && [MailWorkState.retry, .blocked].contains(work?.state)
        cancel.isEnabled = ready && work != nil && work?.state != .sending && work?.state != .uncertain && (work?.attempts == 0 || (work?.kind == .outbox && work?.remote == nil))
        recover.isEnabled = ready && [MailWorkState.uncertain, .blocked].contains(work?.state)
        refreshButton.isEnabled = ready
        changes.isEnabled = !authorizing && account.numberOfItems > 0; sending.isEnabled = changes.isEnabled
        account.isEnabled = !authorizing
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        if case .work(let value) = selection { status.stringValue = value.error ?? "Queued changes wait for connectivity and consent. Cancel is available before provider work begins." }
    }
    @objc private func openSelected() { guard !busy, case .draft(let value) = selection else { return }; onOpen?(value.id) }
    private func consent(_ access: MailAccess) {
        guard !authorizing, let id = account.selectedItem?.representedObject as? String else { return }
        onConsent?(id, access)
    }
    private func deleteDraft() {
        guard !busy, case .draft(let value) = selection else { return }
        confirm("Delete this local mail draft?", detail: "This removes its saved text from this Mac. It does not delete a provider message.") { [weak self] in
            self?.run(["command": CoreCommand.deleteMailDraft.rawValue, "id": value.id, "revision": value.revision])
        }
    }
    private func work(_ choice: MailWorkChoice) {
        guard !busy, case .work(let value) = selection else { return }
        let command: [String: Any] = ["command": CoreCommand.mailWork.rawValue, "id": value.id, "kind": value.kind.rawValue, "choice": choice.rawValue]
        if choice == .retry { run(command); return }
        let detail = choice == .forget ? "Check Sent, provider Drafts and the destination first. Acknowledging removes this stopped operation. It does not undo a provider change. A stopped send is recovered as a local draft; sending it again may create a duplicate." : "Cancel the local operation. A send returns to local drafts. A mail change is restored only if provider work has not begun."
        confirm(choice == .forget ? "Have you checked the provider result?" : "Cancel this queued operation?", detail: detail) { [weak self] in self?.run(command) }
    }
    private func confirm(_ title: String, detail: String, action: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        busy = true; updateButtons(); let revision = generation
        let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, generation == revision else { return }; busy = false; updateButtons()
            if response == .alertFirstButtonReturn { action() }
        }
        if WindowPresentation.isBackground { reply(WindowPresentation.runAlert(alert)) } else { alert.beginSheetModal(for: window, completionHandler: reply) }
    }
    private func run(_ command: [String: Any]) {
        guard !busy else { return }; busy = true; updateButtons(); let revision = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let _: EmptyReply = try await core.request(command, mode: .live)
                guard generation == revision else { return }
                busy = false; onChange?(); refresh()
            } catch { guard generation == revision else { return }; busy = false; updateButtons(); status.stringValue = error.localizedDescription }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell) ?? ClassicTableCell(); cell.identifier = id
        let title: String
        switch rows[row] { case .draft(let value): title = "Draft: " + value.subject; case .work(let value): title = value.kind.rawValue.capitalized + " · " + value.state.rawValue.capitalized + ": " + value.subject }
        cell.configure(title.isEmpty ? "(Untitled)" : title); return cell
    }
}

extension MailWorkspacePanel {
    func verifyControls(accounts: [Account]) async throws {
        precondition(WindowPresentation.isBackground)
        open(accounts: accounts); await task?.value
        guard !openButton.isEnabled, !retry.isEnabled else { throw MailError(message: "Workspace actions enabled without a selection") }
        guard let row = rows.firstIndex(where: { if case .draft = $0 { return true }; return false }) else { throw MailError(message: "No saved draft for workspace control test") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        var opened = 0; onOpen = { _ in opened += 1 }; openButton.performClick(nil)
        guard opened == 1, !openButton.isHighlighted else { throw MailError(message: "Open draft did not dispatch") }
        remove.performClick(nil)
        guard !busy, WindowPresentation.lastDialog?.title == "Delete this local mail draft?" else { throw MailError(message: "Cancelled draft delete left controls blocked") }
        var access: [MailAccess] = []; onConsent = { _, value in access.append(value) }
        changes.performClick(nil); sending.performClick(nil)
        guard access == [.changes, .send] else { throw MailError(message: "Mail consent controls did not dispatch separate access modes") }
        setAuthorizing(.busy); guard !changes.isEnabled, !sending.isEnabled else { throw MailError(message: "Repeated consent remained enabled") }; setAuthorizing(.ready)
        close()
    }
}
