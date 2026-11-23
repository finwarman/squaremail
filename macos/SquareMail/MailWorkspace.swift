import AppKit
import ClassicKit

@MainActor
final class MailWorkspacePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private enum Key: Equatable { case draft(String), work(MailWorkKind, String) }
    private enum Row {
        case draft(DraftSummary), work(MailWorkSummary)
        var key: Key {
            switch self { case .draft(let value): return .draft(value.id); case .work(let value): return .work(value.kind, value.id) }
        }
    }
    private let core: MailCore
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let signInPanel = ClassicPanel()
    private let signInTitle = NSTextField(labelWithString: "")
    private let signInAccount = NSTextField(labelWithString: "")
    private let signInHint = NSTextField(labelWithString: "")
    private let cancelSignIn = ClassicButton("Cancel sign-in")
    private var signIn = MailSignIn.idle
    private let account = NSPopUpButton(frame: .zero)
    private let changes = ClassicButton("Enable mail changes…")
    private let sending = ClassicButton("Enable sending…")
    private let openButton = ClassicButton("Open draft")
    private let remove = ClassicButton("Delete draft")
    private let retry = ClassicButton("Retry")
    private let cancel = ClassicButton("Cancel queued")
    private let recover = ClassicButton("Resolve stopped…")
    private let refreshButton = ClassicButton("Refresh")
    private let history = ClassicButton("Sent history", style: .toggle)
    private let emptyState = NSTextField(wrappingLabelWithString: "")
    private var snapshot: MailWorkspace?
    private let status = NSTextField(wrappingLabelWithString: "Local drafts, queued changes and sends. Nothing is permanently deleted at the provider.")
    private var rows: [Row] = []
    private var queuedFocus: QueuedSend?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var opened = false
    private var busy = false
    var onOpen: ((String) -> Void)?
    var onChange: (() -> Void)?
    var onConsent: ((String, MailAccess) -> Void)?
    var onCancelSignIn: (() -> Void)?
    init(core: MailCore) {
        self.core = core; super.init()
        window.title = "Mail drafts / outbox"; window.isReleasedWhenClosed = false; window.delegate = self
        window.backgroundColor = ClassicTheme.face
        window.contentView?.wantsLayer = true; window.contentView?.layer?.backgroundColor = ClassicTheme.face.cgColor
        scroll.frame = NSRect(x: 10, y: 125, width: 760, height: 395); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mail-work")); column.width = 740; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 46; table.style = .plain; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Local mail drafts and queued work")
        window.contentView?.addSubview(scroll)
        signInPanel.frame = NSRect(x: 10, y: 440, width: 760, height: 80)
        signInPanel.edge = .sunken; signInPanel.isHidden = true
        signInTitle.frame = NSRect(x: 10, y: 8, width: 570, height: 18)
        signInAccount.frame = NSRect(x: 10, y: 29, width: 570, height: 18)
        signInHint.frame = NSRect(x: 10, y: 51, width: 570, height: 18)
        for field in [signInTitle, signInAccount, signInHint] {
            field.font = ClassicTheme.font(11); field.textColor = ClassicTheme.ink
            field.lineBreakMode = .byTruncatingTail; signInPanel.addSubview(field)
        }
        signInTitle.font = ClassicTheme.font(11, weight: .bold)
        cancelSignIn.frame = NSRect(x: 600, y: 26, width: 148, height: 27)
        cancelSignIn.toolTip = "Stop this sign-in. This does not cancel queued mail or undo an accepted send."
        cancelSignIn.onPress = { [weak self] in self?.onCancelSignIn?() }
        signInPanel.addSubview(cancelSignIn); window.contentView?.addSubview(signInPanel)
        for (index, button) in [openButton, remove, retry, cancel, recover, refreshButton].enumerated() {
            button.frame = NSRect(x: 10 + index * 126, y: 91, width: 120, height: 27); window.contentView?.addSubview(button)
        }
        account.frame = NSRect(x: 10, y: 56, width: 315, height: 26)
        changes.frame = NSRect(x: 335, y: 56, width: 210, height: 27); sending.frame = NSRect(x: 555, y: 56, width: 210, height: 27)
        status.frame = NSRect(x: 10, y: 5, width: 580, height: 44); status.font = ClassicTheme.font(10); status.textColor = ClassicTheme.ink
        history.frame = NSRect(x: 610, y: 12, width: 155, height: 27)
        history.toolTip = "Show or hide completed provider-accepted sends. These are not queued or waiting."
        history.onPress = { [weak self] in
            guard let self, let snapshot else { return }
            apply(snapshot, selected: selection?.key)
        }
        emptyState.frame = NSRect(x: 30, y: 270, width: 720, height: 70)
        emptyState.font = ClassicTheme.font(13); emptyState.textColor = ClassicTheme.muted; emptyState.alignment = .center
        emptyState.setAccessibilityLabel("Outbox status")
        for view in [account, changes, sending, status, history, emptyState] { window.contentView?.addSubview(view) }
        openButton.onPress = { [weak self] in self?.openSelected() }
        remove.onPress = { [weak self] in self?.deleteDraft() }
        refreshButton.onPress = { [weak self] in self?.refresh() }
        retry.onPress = { [weak self] in self?.work(.retry) }; cancel.onPress = { [weak self] in self?.work(.cancel) }; recover.onPress = { [weak self] in self?.work(.forget) }
        changes.onPress = { [weak self] in self?.consent(.changes) }; sending.onPress = { [weak self] in self?.consent(.send) }
        updateButtons()
    }
    func open(accounts: [Account], queued: QueuedSend? = nil) {
        let selected = queued?.account ?? account.selectedItem?.representedObject as? String
        queuedFocus = queued
        generation += 1; task?.cancel(); busy = false
        account.removeAllItems()
        for value in accounts where value.provider != .local { account.addItem(withTitle: value.email); account.lastItem?.representedObject = value.id }
        if let index = account.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { account.selectItem(at: index) }
        opened = true; setSignIn(signIn); window.center(); WindowPresentation.show(window); refresh()
    }
    func close() { opened = false; generation += 1; task?.cancel(); task = nil; window.close() }
    func windowWillClose(_ notification: Notification) { opened = false; generation += 1; task?.cancel(); task = nil }
    func setSignIn(_ value: MailSignIn) {
        signIn = value
        signInPanel.isHidden = value == .idle
        scroll.frame.size.height = value == .idle ? 395 : 305
        if let context = value.context {
            signInAccount.stringValue = "Account: " + context.account
            switch value {
            case .waiting:
                signInTitle.stringValue = "Waiting for browser: " + context.purpose.title
                signInHint.stringValue = "Finish consent in your browser, or cancel this sign-in."
            case .cancelling:
                signInTitle.stringValue = "Cancelling sign-in: " + context.purpose.title
                signInHint.stringValue = "Stopping the sign-in request. This does not cancel queued mail."
            case .failed(_, let message):
                signInTitle.stringValue = "Sign-in needs attention: " + context.purpose.title
                signInHint.stringValue = message
            case .idle: break
            }
            for field in [signInTitle, signInAccount, signInHint] { field.toolTip = field.stringValue; field.setAccessibilityLabel(field.stringValue) }
        }
        cancelSignIn.title = value.active ? "Cancel sign-in" : "Dismiss"
        cancelSignIn.isEnabled = value.canCancel || !value.active
        signInPanel.setAccessibilityLabel("Account sign-in status")
        updateButtons()
    }
    func showStatus(_ value: String) { status.stringValue = value }
    func refresh() {
        guard opened, !busy else { return }
        let selected = queuedFocus.map { Key.work(.outbox, $0.id) } ?? selection?.key
        generation += 1; let revision = generation; task?.cancel(); busy = true; updateButtons()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let values: MailWorkspace = try await core.request(["command": CoreCommand.mailWorkspace.rawValue], mode: .live)
                guard generation == revision else { return }
                if let selected, (values.receipts ?? []).contains(where: { Key.work(.outbox, $0.id) == selected }) { history.state = .on }
                busy = false; queuedFocus = nil
                apply(values, selected: selected)
            } catch { guard generation == revision else { return }; busy = false; updateButtons(); status.stringValue = error.localizedDescription }
        }
    }
    private func apply(_ values: MailWorkspace, selected: Key?) {
        snapshot = values
        let receipts = values.receipts ?? []
        rows = values.drafts.map(Row.draft) + values.work.map(Row.work) + (history.state == .on ? receipts.map(Row.work) : [])
        table.deselectAll(nil); table.reloadData()
        history.title = "Sent history (\(receipts.count))"
        history.isEnabled = !busy && !receipts.isEmpty
        emptyState.isHidden = !rows.isEmpty
        emptyState.stringValue = "No queued work.\n" + (receipts.isEmpty ? "New drafts and pending changes will appear here." : "Recent sends are complete. Use Sent history to view their receipts.")
        status.stringValue = values.work.isEmpty ? "No pending work · \(values.drafts.count) local drafts · \(receipts.count) completed send(s)" : "\(values.work.count) queued/stopped · \(values.drafts.count) local drafts · provider updates run in the background"
        if let index = rows.firstIndex(where: { $0.key == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        updateButtons()
    }
    private var selection: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func updateButtons() {
        let ready = !busy
        table.isEnabled = ready
        let draft: Bool; let work: MailWorkSummary?
        switch selection { case .draft: draft = true; work = nil; case .work(let value): draft = false; work = value; default: draft = false; work = nil }
        openButton.isEnabled = ready && draft; remove.isEnabled = ready && draft
        retry.isEnabled = ready && [MailWorkState.retry, .blocked].contains(work?.state)
        cancel.isEnabled = ready && [MailWorkState.pending, .retry, .blocked].contains(work?.state) && (work?.attempts == 0 || (work?.kind == .outbox && work?.remote == nil))
        recover.isEnabled = ready && [MailWorkState.uncertain, .blocked].contains(work?.state)
        refreshButton.isEnabled = ready
        history.isEnabled = ready && !(snapshot?.receipts ?? []).isEmpty
        changes.isEnabled = ready && !signIn.active && account.numberOfItems > 0; sending.isEnabled = changes.isEnabled
        account.isEnabled = ready && !signIn.active
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        if case .work(let value) = selection {
            if let index = account.itemArray.firstIndex(where: { $0.representedObject as? String == value.account }) { account.selectItem(at: index) }
            switch value.state {
            case .done: status.stringValue = "Completed. Accepted by the provider, not queued. Sent folder updates on sync; delivery is not confirmed."
            case .pending: status.stringValue = value.kind == .outbox ? "Queued, not yet sent. Delivery runs in the background while the app is open and online." : "Saved on this Mac. Waiting for provider sync while the app is open and online."
            case .sending: status.stringValue = value.kind == .outbox ? "Sending to the provider…" : "Updating the provider… The local change is already saved."
            case .retry: status.stringValue = "Waiting to retry. " + (value.error ?? "The provider retry delay is preserved.")
            case .blocked, .uncertain: status.stringValue = value.error ?? "Needs attention. Select Resolve stopped to review this operation."
            }
        }
    }
    @objc private func openSelected() { guard !busy, case .draft(let value) = selection else { return }; onOpen?(value.id) }
    private func consent(_ access: MailAccess) {
        guard !signIn.active, let id = account.selectedItem?.representedObject as? String else { return }
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
        switch rows[row] { case .draft(let value): title = "Draft: " + value.subject; case .work(let value): title = (value.kind == .outbox && value.state == .done ? "✓ Completed · Provider accepted" : value.kind.rawValue.capitalized + " · " + value.state.rawValue.capitalized) + ": " + value.subject }
        cell.configure(title.isEmpty ? "(Untitled)" : title); return cell
    }
}

extension MailWorkspacePanel {
    func verifyQueued(accounts: [Account], queued: QueuedSend) async throws {
        precondition(WindowPresentation.isBackground)
        open(accounts: accounts, queued: queued); await task?.value
        guard case .work(let item) = selection, item.id == queued.id, item.kind == .outbox,
              account.selectedItem?.representedObject as? String == queued.account,
              status.stringValue.contains("not yet sent"), sending.isEnabled else { throw MailError(message: "Queued send did not expose its state and correct account") }
        refresh(); await task?.value
        guard case .work(let saved) = selection, saved.id == queued.id else { throw MailError(message: "Outbox refresh hid the selected send state") }
        close()
    }
    private func verifySignIn(accounts: [Account]) async throws {
        let context = SignInContext(account: "fin@example.test", purpose: .mail(.send))
        let originalRows = rows.map(\.key); let originalStatus = status.stringValue
        setSignIn(.waiting(context))
        guard status.stringValue == originalStatus, !signInPanel.isHidden, signInAccount.stringValue.contains(context.account), signInTitle.stringValue.contains("Enable sending"),
              cancelSignIn.isEnabled, !changes.isEnabled, !sending.isEnabled, !scroll.frame.intersects(signInPanel.frame) else { throw MailError(message: "Outbox hid or overlapped the account sign-in state") }
        refresh(); await task?.value
        guard signIn == .waiting(context) else { throw MailError(message: "Outbox refresh cleared the sign-in state") }
        close(); open(accounts: accounts); await task?.value
        guard signIn == .waiting(context), !signInPanel.isHidden else { throw MailError(message: "Reopening outbox lost the pending account") }
        var cancellations = 0
        onCancelSignIn = { [weak self] in cancellations += 1; self?.setSignIn(.cancelling(context)) }
        cancelSignIn.performClick(nil); cancelSignIn.performClick(nil)
        guard cancellations == 1, signIn == .cancelling(context), !cancelSignIn.isEnabled,
              rows.map(\.key) == originalRows else { throw MailError(message: "Sign-in cancellation duplicated work or changed queued mail") }
        try WindowPresentation.snapshot(window.contentView!, name: "outbox-signin-cancelling")
        setSignIn(.waiting(context)); try WindowPresentation.snapshot(window.contentView!, name: "outbox-signin-waiting")
        setSignIn(.failed(context, "Synthetic sign-in error"))
        guard cancelSignIn.title == "Dismiss", signInHint.stringValue == "Synthetic sign-in error", changes.isEnabled, sending.isEnabled else { throw MailError(message: "Failed sign-in left outbox controls blocked") }
        onCancelSignIn = { [weak self] in self?.setSignIn(.idle) }; cancelSignIn.performClick(nil)
        guard signInPanel.isHidden, scroll.frame.maxY == 520, changes.isEnabled, sending.isEnabled else { throw MailError(message: "Sign-in completion left a gap or disabled controls") }
        showStatus(originalStatus)
    }
    private func verifyReceipts(accounts: [Account]) throws {
        let saved = snapshot
        let receipt = MailWorkSummary(id: "accepted-fixture", account: accounts[0].id, state: .done, error: nil, attempts: 1, remote: nil, subject: "Completed synthetic send", kind: .outbox)
        history.state = .off
        apply(MailWorkspace(drafts: [], work: [], receipts: [receipt]), selected: nil)
        guard rows.isEmpty, !emptyState.isHidden, status.stringValue.contains("No pending work") else { throw MailError(message: "Accepted sends looked like pending work") }
        try WindowPresentation.snapshot(window.contentView!, name: "outbox-empty-complete")
        history.performClick(nil); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        guard rows.count == 1, !retry.isEnabled, !cancel.isEnabled, status.stringValue.contains("not queued") else { throw MailError(message: "Completed history exposed queued-send actions") }
        try WindowPresentation.snapshot(window.contentView!, name: "outbox-sent-history")
        history.performClick(nil)
        if let saved { apply(saved, selected: nil) }
    }
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
        try await verifySignIn(accounts: accounts)
        try verifyReceipts(accounts: accounts)
        close()
    }
}
