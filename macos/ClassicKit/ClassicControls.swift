import AppKit

public final class ClassicCheckbox: NSButton {
    public init(_ title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:)") }
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 3, y: floor((bounds.height - 13) / 2), width: 13, height: 13)
        ClassicTheme.light.setFill(); rect.fill()
        ClassicTheme.bevel(rect, edge: .sunken)
        if state == .on {
            (isEnabled ? ClassicTheme.ink : ClassicTheme.shadow).setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 6))
            path.line(to: NSPoint(x: rect.minX + 5, y: rect.minY + 9))
            path.line(to: NSPoint(x: rect.minX + 10, y: rect.minY + 3))
            path.lineWidth = 2
            path.stroke()
        }
        ClassicTheme.text(title, in: NSRect(x: 23, y: floor((bounds.height - 16) / 2), width: bounds.width - 25, height: 17),
                          size: 10, color: isEnabled ? ClassicTheme.ink : ClassicTheme.shadow)
    }
}

public final class ClassicButton: NSButton {
    public override var title: String { didSet { setAccessibilityLabel(title); needsDisplay = true } }
    public override var isEnabled: Bool { didSet { if !isEnabled { hovered = false; highlight(false) }; needsDisplay = true } }
    public enum Style { case normal, toolbar, navigation, toggle, iconToggle, segment, title, menu }
    private var helpText: String?
    public override var toolTip: String? { get { helpText } set { helpText = newValue; setAccessibilityHelp(newValue) } }
    public var onPress: (() -> Void)?
    public var icon: ClassicIcon?
    private let style: Style
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var isToolbar: Bool { style == .toolbar || style == .navigation }
    private var isCommand: Bool { style == .normal || style == .toolbar || style == .menu || style == .title }

    public init(_ title: String, icon: ClassicIcon? = nil, style: Style = .normal) {
        self.style = style
        self.icon = icon
        super.init(frame: .zero)
        self.title = title
        self.font = ClassicTheme.font()
        self.isBordered = false
        self.setButtonType(style == .toggle || style == .iconToggle || style == .segment ? .pushOnPushOff : .momentaryPushIn)
        self.target = self
        self.action = #selector(pressed)
        self.setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:)") }
    public override var isFlipped: Bool { true }

    @objc private func pressed() {
        ClassicHelp.shared.hide()
        defer { highlight(false); if isCommand { state = .off }; needsDisplay = true }
        hovered = false; highlight(false)
        if isCommand { state = .off }
        // Release before callbacks can enter a modal loop or cover this window.
        needsDisplay = true; displayIfNeeded()
        onPress?()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; ClassicHelp.shared.show(toolTip, from: self) }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; ClassicHelp.shared.hide() }

    public override func draw(_ dirtyRect: NSRect) {
        ClassicTheme.face.setFill(); bounds.fill()
        let down = isHighlighted || state == .on
        if (!isToolbar && style != .menu) || hovered || down {
            ClassicTheme.bevel(bounds, edge: down ? .sunken : .raised)
        }
        let shift: CGFloat = down ? 1 : 0
        let ink = isEnabled ? ClassicTheme.ink : ClassicTheme.muted
        if style == .segment && state == .on {
            ClassicTheme.selection.withAlphaComponent(0.12).setFill(); bounds.insetBy(dx: 2, dy: 2).fill()
        }
        if style == .iconToggle {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.45)
            if let icon { icon.draw(in: NSRect(x: floor((bounds.width - 16) / 2) + shift, y: floor((bounds.height - 16) / 2) + shift, width: 16, height: 16)) }
            NSGraphicsContext.restoreGraphicsState()
        } else if isToolbar {
            if let icon { icon.draw(in: NSRect(x: (bounds.width - 24) / 2 + shift, y: 5 + shift, width: 24, height: 24)) }
            ClassicTheme.text(title, in: NSRect(x: 2 + shift, y: 34 + shift, width: bounds.width - 4, height: 18), size: 11, color: ink, alignment: .center)
        } else {
            let width = (title as NSString).size(withAttributes: [.font: ClassicTheme.font()]).width
            let total = width + (icon == nil ? 0 : 24)
            let left = floor((bounds.width - total) / 2) + shift
            if let icon { icon.draw(in: NSRect(x: left, y: floor((bounds.height - 16) / 2) + shift, width: 16, height: 16)) }
            ClassicTheme.text(title, in: NSRect(x: left + (icon == nil ? 0 : 24), y: floor((bounds.height - 16) / 2) + shift, width: width + 3, height: 18), color: ink)
        }
        if window?.firstResponder === self {
            ClassicTheme.shadow.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            path.setLineDash([1, 1], count: 2, phase: 0); path.stroke()
        }
    }
}

public final class ClassicHeaderCell: NSTableHeaderCell {
    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        ClassicTheme.face.setFill(); cellFrame.fill()
        ClassicTheme.bevel(cellFrame)
        ClassicTheme.text(stringValue, in: cellFrame.insetBy(dx: 7, dy: 4), size: 11)
    }

    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
}

public final class ClassicRow: NSTableRowView {
    public override var isSelected: Bool {
        didSet { updateCells() }
    }

    public override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateCells()
    }

    private func updateCells() {
        for case let cell as NSTableCellView in subviews {
            cell.backgroundStyle = interiorBackgroundStyle
        }
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        backgroundColor.setFill(); bounds.fill()
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        ClassicTheme.selection.setFill(); bounds.fill()
    }
}

public final class ClassicTableCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var icon: ClassicIcon?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        textField = label
        label.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public func configure(_ text: String, weight: ClassicTheme.Weight = .regular, icon: ClassicIcon? = nil) {
        label.stringValue = text
        label.font = ClassicTheme.font(12, weight: weight)
        self.icon = icon
        needsLayout = true; needsDisplay = true
        setAccessibilityLabel(text)
    }

    public override var backgroundStyle: NSView.BackgroundStyle {
        didSet { label.textColor = backgroundStyle == .emphasized ? .white : ClassicTheme.ink }
    }

    public override func layout() {
        super.layout()
        let inset: CGFloat = icon == nil ? 7 : 28
        label.frame = NSRect(x: inset, y: floor((bounds.height - 18) / 2), width: max(0, bounds.width - inset - 5), height: 18)
    }

    public override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: NSRect(x: 5, y: floor((bounds.height - 16) / 2), width: 16, height: 16))
    }
}
