import AppKit
import ClassicKit

@MainActor
final class PendingEdits: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let core: MailCore
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Conflicts require reopening the current event. Discarding an uncertain operation does not undo a provider change.")
    private var items: [EventWrite] = []
    private var task: Task<Void, Never>?
    var onOpen: ((EventKey) -> Void)?
    init(core: MailCore) {
        self.core = core
        super.init()
        window.title = "Pending calendar changes (maximum 50)"
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 92, width: 640, height: 278))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pending-edit"))
        column.width = 620; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 52
        table.style = .plain; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Pending calendar changes")
        let refresh = ClassicButton("Refresh")
        let open = ClassicButton("Open event")
        let discard = ClassicButton("Discard selected")
        for (index, button) in [refresh, open, discard].enumerated() {
            button.frame = NSRect(x: 10 + index * 155, y: 53, width: 145, height: 28)
            window.contentView?.addSubview(button)
        }
        refresh.onPress = { [weak self] in self?.load() }
        open.onPress = { [weak self] in
            guard let self, items.indices.contains(table.selectedRow) else { return }
            let value = items[table.selectedRow]
            guard value.id != nil else { status.stringValue = "A new event has no provider ID until creation succeeds."; return }
            onOpen?(EventKey(account: value.account, calendar: value.calendar, id: value.id))
        }
        discard.onPress = { [weak self] in self?.discard() }
        status.frame = NSRect(x: 10, y: 8, width: 640, height: 38); status.font = ClassicTheme.font(10)
        window.contentView?.addSubview(scroll); window.contentView?.addSubview(status)
    }
    func open() { window.center(); window.makeKeyAndOrderFront(nil); load() }
    func close() { task?.cancel(); task = nil; window.close() }
    private func load() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let rows: [EventWrite] = try await core.request(["command": CoreCommand.eventWrites.rawValue], mode: .live)
                guard !Task.isCancelled else { return }
                items = rows; table.reloadData()
            } catch is CancellationError {} catch { status.stringValue = error.localizedDescription }
        }
    }
    private func discard() {
        guard items.indices.contains(table.selectedRow) else { return }
        let item = items[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = "Discard this queued edit?"
        alert.informativeText = "This removes the local operation. If its result was uncertain, check the provider before creating another event. It does not undo a saved event."
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        task = Task {
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.discardEvent.rawValue, "operation": item.operation], mode: .live)
                load()
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell) ?? ClassicTableCell()
        cell.identifier = id
        let item = items[row]
        cell.configure(item.state.rawValue.capitalized + ": " + item.title + (item.error.map { " · " + $0 } ?? ""))
        cell.toolTip = item.error
        return cell
    }
}
