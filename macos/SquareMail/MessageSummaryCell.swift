import AppKit
import ClassicKit

final class MessageSummaryCell: NSTableCellView {
    private let sender = NSTextField(labelWithString: "")
    private let subject = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private var icon: ClassicIcon?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [sender, subject, preview, date] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        sender.font = ClassicTheme.font(11)
        preview.font = ClassicTheme.font(11)
        date.font = ClassicTheme.font(10)
        date.alignment = .right
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(_ mail: Mail, date value: String) {
        sender.stringValue = mail.sender.isEmpty ? mail.senderAddress : mail.sender
        sender.font = ClassicTheme.font(11, weight: mail.unread ? .bold : .regular)
        subject.stringValue = (mail.pinned == true ? "Pinned · " : "") + mail.subject
        subject.font = ClassicTheme.font(12, weight: mail.unread ? .bold : .regular)
        preview.stringValue = mail.preview
        date.stringValue = value
        icon = mail.starred ? .star : (mail.hasAttachments ? .attach : (mail.unread ? .mail : nil))
        setAccessibilityLabel([sender.stringValue, value, mail.subject, mail.preview].joined(separator: ". "))
        needsLayout = true
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        sender.textColor = selected ? .white : ClassicTheme.ink
        subject.textColor = selected ? .white : ClassicTheme.ink
        preview.textColor = selected ? .white : ClassicTheme.muted
        date.textColor = selected ? .white : ClassicTheme.muted
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 28
        sender.frame = NSRect(x: inset, y: 7, width: max(0, bounds.width - inset - 105), height: 16)
        date.frame = NSRect(x: max(inset, bounds.width - 103), y: 7, width: 93, height: 16)
        subject.frame = NSRect(x: inset, y: 25, width: max(0, bounds.width - inset - 10), height: 18)
        preview.frame = NSRect(x: inset, y: 46, width: max(0, bounds.width - inset - 10), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: NSRect(x: 7, y: 8, width: 16, height: 16))
    }
}
