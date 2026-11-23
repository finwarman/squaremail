import AppKit
import ClassicKit

struct ContactSuggestion: Decodable { let name: String; let address: String }

@MainActor
final class AddressSuggestions: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Phase { case idle, typing, accepting }
    private enum Command: String { case down = "moveDown:", up = "moveUp:", accept = "insertNewline:", tab = "insertTab:", cancel = "cancelOperation:" }
    private let core: MailCore
    private let panel = SuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private weak var field: NSTextField?
    private weak var parent: NSWindow?
    private var suggestions: [ContactSuggestion] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var phase = Phase.idle
    private var replacement = NSRange(location: 0, length: 0)
    private var opened = false
    var onCommit: (() -> Void)?
    init(core: MailCore) {
        self.core = core; super.init()
        panel.hasShadow = true; panel.isReleasedWhenClosed = false; panel.becomesKeyOnlyIfNeeded = true; panel.appearance = NSAppearance(named: .aqua)
        let face = ClassicPanel(); face.edge = .raised; panel.contentView = face
        scroll.documentView = table; scroll.hasVerticalScroller = true; face.addSubview(scroll)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address")))
        table.headerView = nil; table.rowHeight = 42; table.style = .plain; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(choose)
        table.setAccessibilityLabel("Suggested recipient addresses")
    }
    func update(_ field: NSTextField, account: String?) {
        guard phase != .accepting else { return }
        dismiss(); phase = .typing
        guard let account, let editor = field.currentEditor() as? NSTextView, editor.selectedRange().length == 0,
              let token = Self.token(editor.string, caret: editor.selectedRange().location) else { return }
        self.field = field; replacement = token.range
        let revision = generation
        task = Task { [weak self, weak field, weak editor] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            do {
                let values: [ContactSuggestion] = try await core.request(["command": CoreCommand.contacts.rawValue, "account": account, "query": token.text], mode: .live)
                guard !Task.isCancelled, generation == revision, let field, let editor,
                      field.currentEditor() === editor, Self.token(editor.string, caret: editor.selectedRange().location)?.text == token.text else { return }
                suggestions = values; if !values.isEmpty { present(field) }
            } catch { if generation == revision { hide() } }
        }
    }
    private static func token(_ text: String, caret: Int) -> (text: String, range: NSRange)? {
        let value = text as NSString
        guard caret > 0, caret <= value.length else { return nil }
        // Do not complete inside an existing address. Only a trailing token is replaced.
        let suffix = value.substring(from: caret).components(separatedBy: CharacterSet(charactersIn: ",;")).first ?? ""
        guard suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prefix = value.substring(to: caret) as NSString
        let separator = prefix.rangeOfCharacter(from: CharacterSet(charactersIn: ",;"), options: .backwards)
        let start = separator.location == NSNotFound ? 0 : NSMaxRange(separator)
        let raw = value.substring(with: NSRange(location: start, length: caret - start))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.utf8.count <= 128 else { return nil }
        let leading = (raw as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
        guard leading != NSNotFound else { return nil }
        return (trimmed, NSRange(location: start + leading, length: caret - start - leading))
    }
    private func present(_ field: NSTextField) {
        guard let window = field.window else { return }
        let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let height = CGFloat(min(suggestions.count, 8)) * table.rowHeight + 4
        let width = min(520, max(300, field.bounds.width))
        let screen = window.screen?.visibleFrame ?? rect
        let y = rect.minY - height < screen.minY ? rect.maxY : rect.minY - height
        panel.setFrame(NSRect(x: min(rect.minX, screen.maxX - width), y: y, width: width, height: height), display: false)
        scroll.frame = panel.contentView!.bounds.insetBy(dx: 2, dy: 2); table.sizeLastColumnToFit(); table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        parent = window; window.addChildWindow(panel, ordered: .above); opened = true
        if !WindowPresentation.isBackground { panel.orderFront(nil) }
    }
    func command(_ command: Selector) -> Bool {
        guard opened else { return false }
        guard let action = Command(rawValue: NSStringFromSelector(command)) else { return false }
        switch action {
        case .down: table.selectRowIndexes(IndexSet(integer: min(suggestions.count - 1, table.selectedRow + 1)), byExtendingSelection: false)
        case .up: table.selectRowIndexes(IndexSet(integer: max(0, table.selectedRow - 1)), byExtendingSelection: false)
        case .accept: choose()
        case .tab: let window = parent; choose(); window?.selectNextKeyView(nil)
        case .cancel: dismiss()
        }
        if opened, table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        return true
    }
    @objc private func choose() {
        guard suggestions.indices.contains(table.selectedRow), let field, let editor = field.currentEditor() as? NSTextView,
              NSMaxRange(replacement) <= (editor.string as NSString).length, editor.selectedRange().length == 0, editor.selectedRange().location == NSMaxRange(replacement) else { dismiss(); return }
        let address = suggestions[table.selectedRow].address
        phase = .accepting; generation += 1; task?.cancel()
        editor.insertText(address, replacementRange: replacement)
        onCommit?(); hide(); phase = .idle
    }
    func dismiss() { generation += 1; task?.cancel(); task = nil; hide(); phase = .idle }
    private func hide() { parent?.removeChildWindow(panel); panel.orderOut(nil); parent = nil; opened = false; suggestions.removeAll(); table.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("contact-row")
        let value = tableView.makeView(withIdentifier: id, owner: self) as? ClassicRow ?? ClassicRow(); value.identifier = id; return value
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard suggestions.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ContactCell ?? ContactCell(); cell.identifier = id
        cell.configure(suggestions[row])
        return cell
    }
}
private final class SuggestionPanel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }

extension AddressSuggestions {
    func verify(_ field: NSTextField, account: String) async throws {
        guard WindowPresentation.isBackground, let editor = field.currentEditor() as? NSTextView else { throw MailError(message: "Use hidden address fixture") }
        editor.string = "first@example.test,   ad"; editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let original = field.window?.firstResponder
        update(field, account: account); await task?.value
        guard opened, suggestions.contains(where: { $0.address == "ada@example.test" }), field.window?.firstResponder === original else { throw MailError(message: "Offline address lookup lost suggestions or focus") }
        try WindowPresentation.snapshot(panel.contentView!, name: "recipient-suggestions")
        guard command(NSSelectorFromString("insertNewline:")), editor.string == "first@example.test,   ada@example.test", !opened else { throw MailError(message: "Address completion replaced another recipient or kept popup open") }
        editor.string = "ad"; editor.setSelectedRange(NSRange(location: 2, length: 0)); update(field, account: account)
        editor.string = "zzzzzz"; editor.setSelectedRange(NSRange(location: 6, length: 0)); update(field, account: account); await task?.value
        guard !opened else { throw MailError(message: "Stale address result reopened the popup") }
        dismiss()
        guard Self.token("ada@example.test", caret: 2) == nil else { throw MailError(message: "Completion could replace part of an existing address") }
    }
}

private final class ContactCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = ClassicTheme.font(11, weight: .bold); address.font = ClassicTheme.font(11)
        for label in [name, address] { label.lineBreakMode = .byTruncatingTail; addSubview(label) }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ value: ContactSuggestion) {
        name.stringValue = value.name.isEmpty ? value.address : value.name
        address.stringValue = value.name.isEmpty ? "" : value.address
        toolTip = value.address; setAccessibilityLabel(value.name + ", " + value.address); paint(); needsLayout = true
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { paint() } }
    private func paint() { for label in [name, address] { label.textColor = backgroundStyle == .emphasized ? .white : ClassicTheme.ink } }
    override func layout() {
        super.layout(); name.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 17)
        address.frame = NSRect(x: 8, y: 22, width: max(0, bounds.width - 16), height: 16)
    }
}
