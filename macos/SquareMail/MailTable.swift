import AppKit

final class MailTable: NSTableView {
    var onTrash: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, ["\u{7f}", "\u{f728}"].contains(event.charactersIgnoringModifiers ?? "") {
            onTrash?(); return
        }
        super.keyDown(with: event)
    }
}
struct MailBatchReceipt: Decodable { let operation: String; let count: Int }
struct MailUndo { let operation: String; let title: String }
