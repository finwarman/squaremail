import AppKit
import MessageText

final class MailTextView: NSTextView {
    var document: PlainDocument?
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let result = super.writeSelection(to: pasteboard, types: types)
        guard let type = types.first(where: { $0 == .string || $0.rawValue == "NSStringPboardType" }),
              let document, !document.links.isEmpty else { return result }
        return pasteboard.setString(document.copyText(selectedRange()), forType: type) || result
    }
}
