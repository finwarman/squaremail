import AppKit

// Reuses native buttons and square theme drawing. Selection remains with the application.
public final class ClassicTabs: NSView {
    private var items: [(ClassicButton, CGFloat)] = []
    private var accessory: (ClassicButton, CGFloat)?
    public override var isFlipped: Bool { true }
    public override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.tabGroup) }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    public func addTab(_ button: ClassicButton, width: CGFloat) {
        button.setAccessibilityRole(.radioButton); items.append((button,width)); addSubview(button); needsLayout = true
    }
    public func setAccessory(_ button: ClassicButton, width: CGFloat) { accessory?.0.removeFromSuperview(); accessory = (button,width); addSubview(button); needsLayout = true }
    public override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill(); ClassicTheme.light.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 1).fill()
    }
    public override func layout() {
        super.layout(); var x: CGFloat = 4
        let total = items.reduce(CGFloat(0)) { $0 + $1.1 + 2 }
        let scale = min(1, max(0, (bounds.width - 8) / max(1, total)))
        for (button,width) in items {
            let selected = button.state == .on
            let available = max(0, (width + 2) * scale - 2)
            button.frame = NSRect(x: x, y: selected ? 0 : 3, width: available, height: bounds.height - (selected ? 0 : 3)); x += available + 2
        }
        if let (button,width) = accessory {
            button.isHidden = bounds.width < x + width + 14
            button.frame = NSRect(x: max(x + 10,bounds.width - width - 4), y: 1, width: width, height: max(0,bounds.height - 4))
        }
    }
}
