import AppKit
import ClassicKit

private final class FolderButton: NSButton {
    let folder: Folder
    private let icon: ClassicIcon
    var onSelect: ((Folder) -> Void)?
    override var isFlipped: Bool { true }

    init(_ folder: Folder, icon: ClassicIcon) {
        self.folder = folder
        self.icon = icon
        super.init(frame: .zero)
        title = folder.title
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(selectFolder)
        setAccessibilityLabel(folder.title)
    }

    required init?(coder: NSCoder) { fatalError("Use init(folder:)") }
    @objc private func selectFolder() { onSelect?(folder) }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        (selected ? ClassicTheme.navy : ClassicTheme.face).setFill()
        bounds.fill()
        if selected { ClassicTheme.bevel(bounds, edge: .sunken) }
        icon.draw(in: NSRect(x: 13, y: 8, width: 16, height: 16))
        ClassicTheme.text(folder.title, in: NSRect(x: 39, y: 9, width: bounds.width - 44, height: 20),
                          color: selected ? .white : ClassicTheme.ink,
                          weight: folder == .inbox ? .bold : .regular)
    }
}

final class Sidebar: NSView {
    let accounts = NSPopUpButton(frame: .zero, pullsDown: false)
    let connect = ClassicButton("Connect an account…", icon: .account)
    let demo = ClassicButton("Demo mailbox", icon: .mail)
    var onFolder: ((Folder) -> Void)?
    private var folders: [FolderButton] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(accounts)
        accounts.font = ClassicTheme.font(11)
        accounts.bezelStyle = .shadowlessSquare
        accounts.setAccessibilityLabel("Mail account")
        let icons: [ClassicIcon] = [.inbox, .mail, .star, .sent, .draft, .folder, .trash, .folder]
        for (index, folder) in Folder.allCases.enumerated() {
            let button = FolderButton(folder, icon: icons[index])
            button.onSelect = { [weak self] folder in self?.onFolder?(folder) }
            addSubview(button)
            folders.append(button)
        }
        addSubview(connect)
        addSubview(demo)
        select(.inbox)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func select(_ folder: Folder) {
        for button in folders { button.state = button.folder == folder ? .on : .off; button.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        accounts.frame = NSRect(x: 10, y: 63, width: bounds.width - 20, height: 27)
        for (index, button) in folders.enumerated() {
            button.frame = NSRect(x: 5, y: 111 + CGFloat(index) * 33, width: bounds.width - 10, height: 33)
        }
        connect.frame = NSRect(x: 10, y: bounds.height - 78, width: bounds.width - 20, height: 28)
        demo.frame = NSRect(x: 10, y: bounds.height - 43, width: bounds.width - 20, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        let heading = NSRect(x: 3, y: 3, width: bounds.width - 6, height: 29)
        NSGradient(starting: ClassicTheme.navy, ending: ClassicTheme.blue)?.draw(in: heading, angle: 0)
        ClassicTheme.text("Folders", in: NSRect(x: 13, y: 9, width: 150, height: 20), color: .white, weight: .bold)
        ClassicTheme.text("Show mail from:", in: NSRect(x: 12, y: 43, width: 170, height: 17), size: 11, color: ClassicTheme.muted)
        ClassicTheme.text("MAILBOX", in: NSRect(x: 13, y: 97, width: 170, height: 16), size: 9, color: ClassicTheme.muted, weight: .bold)
        ClassicTheme.shadow.setFill()
        NSRect(x: 10, y: 391, width: bounds.width - 20, height: 1).fill()
        ClassicTheme.light.setFill()
        NSRect(x: 10, y: 392, width: bounds.width - 20, height: 1).fill()
        if bounds.height > 560 {
            ClassicIcon.mail.draw(in: NSRect(x: 77, y: 423, width: 40, height: 40))
            ClassicTheme.text("Square Mail", in: NSRect(x: 10, y: 477, width: bounds.width - 20, height: 22), size: 14, weight: .bold, alignment: .center)
            ClassicTheme.text("Your mail. On your Mac.", in: NSRect(x: 10, y: 504, width: bounds.width - 20, height: 20), size: 10, color: ClassicTheme.muted, alignment: .center)
        }
    }
}
