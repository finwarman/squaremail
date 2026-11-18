import AppKit

public final class ClassicActionBar: NSView {
    public enum Priority { case primary, secondary }
    private struct Item { let button: ClassicButton; let size: NSSize; let priority: Priority }
    private var items: [Item] = []
    private let more = ClassicButton("More…")
    private let surface = ClassicSurface()
    private static let inset: CGFloat = 6
    private static let gap: CGFloat = 6
    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(more)
        more.onPress = { [weak self] in
            guard let self else { return }
            overflowMenu().popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY), in: self)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public func addItem(_ button: ClassicButton, width: CGFloat, height: CGFloat = 26, priority: Priority = .primary) {
        items.append(Item(button: button, size: NSSize(width: width, height: height), priority: priority))
        addSubview(button); needsLayout = true
    }
    public func fittingHeight(_ width: CGFloat) -> CGFloat { arrangement(width).height }
    public func overflowMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for item in items where item.priority == .secondary && item.button.isHidden {
            let entry = NSMenuItem(title: item.button.title, action: #selector(activateItem), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.button
            entry.isEnabled = item.button.isEnabled; entry.state = item.button.state
            menu.addItem(entry)
        }
        return menu
    }
    @objc private func activateItem(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? ClassicButton, button.isEnabled else { return }
        button.performClick(nil)
    }
    private func arrangement(_ width: CGFloat) -> (frames: [(ClassicButton, NSRect)], height: CGFloat) {
        let fullWidth = items.reduce(Self.inset * 2 - Self.gap) { $0 + $1.size.width + Self.gap }
        let overflow = fullWidth > width && items.contains { $0.priority == .secondary }
        var visible = items.filter { !overflow || $0.priority == .primary }
        if overflow { visible.append(Item(button: more, size: NSSize(width: 76, height: 26), priority: .primary)) }
        var x = Self.inset; var y = Self.inset; var rowHeight: CGFloat = 0
        var frames: [(ClassicButton, NSRect)] = []
        for item in visible {
            let size = NSSize(width: min(item.size.width, max(0, width - Self.inset * 2)), height: item.size.height)
            if x > Self.inset && x + size.width > width - Self.inset {
                x = Self.inset; y += rowHeight + Self.gap; rowHeight = 0
            }
            frames.append((item.button, NSRect(origin: NSPoint(x: x, y: y), size: size)))
            x += size.width + Self.gap; rowHeight = max(rowHeight, size.height)
        }
        return (frames, visible.isEmpty ? 0 : y + rowHeight + Self.inset)
    }
    public override func layout() {
        super.layout()
        let plan = arrangement(bounds.width)
        for item in items { item.button.isHidden = !plan.frames.contains { $0.0 === item.button } }
        more.isHidden = !plan.frames.contains { $0.0 === more }
        if items.contains(where: { $0.button.isHidden && window?.firstResponder === $0.button }) { window?.makeFirstResponder(more) }
        for (button, frame) in plan.frames { button.frame = frame }
        needsDisplay = true
    }
    public override func updateLayer() { surface.update(layer, bounds: bounds, fill: ClassicTheme.face) }
}
