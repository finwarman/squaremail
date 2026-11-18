import AppKit
import ClassicKit

@MainActor
final class PendingEdits: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private enum Phase { case idle, loading, confirming, saving }
    private var phase: Phase = .idle
    private var generation = 0
    private let refreshButton = ClassicButton("Refresh")
    private let openButton = ClassicButton("Open")
    private let discardButton = ClassicButton("Discard selected")
    private let core: MailCore
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Conflicts require reopening the current event. Discarding an uncertain operation does not undo a provider change.")
    private var items: [EventWrite] = []
    private var task: Task<Void, Never>?
    var onDraft: ((LocalEventDraft) -> Void)?
    var onOpen: ((EventKey) -> Void)?
    init(core: MailCore) {
        self.core = core
        super.init()
        window.title = "Calendar drafts / pending (20 drafts, 50 queued)"
        window.isReleasedWhenClosed = false; window.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 92, width: 640, height: 278))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pending-edit"))
        column.width = 620; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 52
        table.style = .plain; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Pending calendar changes")
        for (index, button) in [refreshButton, openButton, discardButton].enumerated() {
            button.frame = NSRect(x: 10 + index * 155, y: 53, width: 145, height: 28)
            window.contentView?.addSubview(button)
        }
        refreshButton.onPress = { [weak self] in self?.load() }
        openButton.onPress = { [weak self] in
            guard let self, items.indices.contains(table.selectedRow) else { return }
            let value = items[table.selectedRow]
            if let draft = value.draft { onDraft?(draft); return }
            guard value.id != nil else { status.stringValue = "A new event has no provider ID until creation succeeds."; return }
            onOpen?(EventKey(account: value.account, calendar: value.calendar, id: value.id))
        }
        discardButton.onPress = { [weak self] in self?.discard() }
        status.frame = NSRect(x: 10, y: 8, width: 640, height: 38); status.font = ClassicTheme.font(10)
        window.contentView?.addSubview(scroll); window.contentView?.addSubview(status)
        updateButtons()
    }
    func open() { window.center(); WindowPresentation.show(window); load() }
    func close() { task?.cancel(); task = nil; generation += 1; phase = .idle; window.close() }
    func windowWillClose(_ notification: Notification) { task?.cancel(); task = nil; generation += 1; phase = .idle }
    private func updateButtons() {
        let selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        refreshButton.isEnabled = phase == .idle
        openButton.isEnabled = phase == .idle && (selected?.draft != nil || selected?.id != nil)
        discardButton.isEnabled = phase == .idle && selected != nil && selected?.state != .sending
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        guard items.indices.contains(table.selectedRow) else { return }
        let item = items[table.selectedRow]
        status.stringValue = item.error ?? (item.state == .draft ? "Saved on this Mac. Open it to continue editing." : (item.id == nil ? "New event is waiting for a provider ID." : "Open the event or discard the local queued change."))
    }
    private func load() {
        task?.cancel(); generation += 1; let revision = generation
        phase = .loading; updateButtons()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let rows: [EventWrite] = try await core.request(["command": CoreCommand.eventWrites.rawValue], mode: .live)
                guard !Task.isCancelled, generation == revision else { return }
                items = rows; table.reloadData()
                phase = .idle; updateButtons()
                status.stringValue = rows.isEmpty ? "No local calendar drafts or pending changes." : "Select a draft or queued change."
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                phase = .idle; updateButtons(); status.stringValue = error.localizedDescription
            }
        }
    }
    private func discard() {
        guard phase == .idle, items.indices.contains(table.selectedRow) else { return }
        let item = items[table.selectedRow]
        guard item.state != .sending else { return }
        let alert = NSAlert()
        alert.messageText = item.state == .draft ? "Delete this local calendar draft?" : "Discard this queued edit?"
        alert.informativeText = item.state == .draft ? "This removes the saved draft from this Mac. Provider calendars are unchanged." : "This removes the local operation. If its result was uncertain, check the provider before creating another event. It does not undo a saved event."
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        phase = .confirming; updateButtons()
        let revision = generation
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, generation == revision else { return }
            phase = .idle; updateButtons()
            guard response == .alertFirstButtonReturn else { return }
            phase = .saving; updateButtons()
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let _: EmptyReply = try await core.request(["command": CoreCommand.discardEvent.rawValue, "operation": item.operation], mode: .live)
                    guard generation == revision else { return }
                    load()
                } catch {
                    guard generation == revision else { return }
                    phase = .idle; updateButtons(); status.stringValue = error.localizedDescription
                }
            }
        }
        if WindowPresentation.isBackground { respond(WindowPresentation.runAlert(alert)) }
        else { alert.beginSheetModal(for: window, completionHandler: respond) }
    }
    func verifyControls() async throws {
        precondition(WindowPresentation.isBackground)
        open(); await task?.value
        guard phase == .idle, !openButton.isEnabled, !discardButton.isEnabled else { throw MailError(message: "Pending actions are enabled without a selection") }
        guard let row = items.firstIndex(where: { $0.state == .draft }) else { throw MailError(message: "Control fixture has no saved draft") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        var opened = 0; onDraft = { _ in opened += 1 }
        openButton.performClick(nil)
        guard opened == 1, !openButton.isHighlighted else { throw MailError(message: "Saved-draft Open did not finish its action") }
        discardButton.performClick(nil)
        guard phase == .idle, discardButton.isEnabled, WindowPresentation.lastDialog?.title == "Delete this local calendar draft?" else { throw MailError(message: "Cancelled discard left pending controls blocked") }
        close()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell) ?? ClassicTableCell()
        cell.identifier = id
        let item = items[row]
        cell.configure(item.state.rawValue.capitalized + ": " + (item.title.isEmpty ? "(Untitled calendar draft)" : item.title) + (item.error.map { " · " + $0 } ?? ""))
        cell.toolTip = item.error
        return cell
    }
}
