import AppKit

public enum ClassicTheme {
    public static let face = color(0xD4D0C8)
    public static let light = color(0xFFFFFF)
    public static let shadow = color(0x808080)
    public static let dark = color(0x404040)
    public static let ink = color(0x161616)
    public static let muted = color(0x5D5B55)
    public static let navy = color(0x0A246A)
    public static let blue = color(0xA6CAF0)
    public static let paper = color(0xFFFFF3)
    public static let selection = color(0x0A246A)
    public static let row = color(0xF5F4EF)

    public enum Weight { case regular, bold }
    public enum Edge { case raised, sunken, flat }

    public static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    public static func font(_ size: CGFloat = 12, weight: Weight = .regular) -> NSFont {
        let names = weight == .bold ? ["Tahoma-Bold", "Verdana-Bold", "Arial-BoldMT"] : ["Tahoma", "Verdana", "ArialMT"]
        for name in names {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.systemFont(ofSize: size)
    }

    public static func bevel(_ rect: NSRect, edge: Edge = .raised) {
        guard edge != .flat else { return }
        let top = edge == .raised ? light : shadow
        let bottom = edge == .raised ? dark : light
        top.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        bottom.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        let inner = rect.insetBy(dx: 1, dy: 1)
        (edge == .raised ? face : dark).setFill()
        NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 1).fill()
        NSRect(x: inner.minX, y: inner.minY, width: 1, height: inner.height).fill()
        (edge == .raised ? shadow : face).setFill()
        NSRect(x: inner.minX, y: inner.maxY - 1, width: inner.width, height: 1).fill()
        NSRect(x: inner.maxX - 1, y: inner.minY, width: 1, height: inner.height).fill()
    }

    public static func text(_ value: String, in rect: NSRect, size: CGFloat = 12,
                            color: NSColor = ink, weight: Weight = .regular,
                            alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        (value as NSString).draw(in: rect, withAttributes: [
            .font: font(size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
}

public final class ClassicPanel: NSView {
    public var edge: ClassicTheme.Edge = .raised
    public var fill: NSColor = ClassicTheme.face
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        ClassicTheme.bevel(bounds, edge: edge)
    }
}

public final class ClassicTitleBar: NSView {
    public var title = "Square Mail"
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: ClassicTheme.navy, ending: ClassicTheme.blue)?.draw(in: bounds, angle: 0)
        ClassicIcon.mail.draw(in: NSRect(x: 6, y: 6, width: 20, height: 20))
        ClassicTheme.text(title, in: NSRect(x: 34, y: 7, width: bounds.width - 132, height: 22),
                          size: 14, color: .white, weight: .bold)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.zoom(nil); return }
        window?.performDrag(with: event)
    }
}
