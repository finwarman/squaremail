import AppKit

public enum ClassicTheme {
    public enum Appearance: String, CaseIterable { case classic, pink }
    public private(set) static var appearance: Appearance = .classic
    // Configure before constructing views. Existing windows retain stored control colors.
    public static func configure(_ value: Appearance) { appearance = value }
    private enum Token: CaseIterable { case face, light, shadow, dark, ink, muted, navy, blue, paper, selection, row, focus, todaySurface, selectedSurface, grid, timeMarker }
    private static let classic = palette(.classic)
    private static let pink = palette(.pink)
    private static func palette(_ appearance: Appearance) -> [Token: NSColor] {
        let hex: [Token: UInt32]
        switch appearance {
        case .classic:
            hex = [.face:0xD4D0C8, .light:0xFFFFFF, .shadow:0x808080, .dark:0x404040, .ink:0x161616, .muted:0x5A5852, .navy:0x0A246A, .blue:0xA6CAF0, .paper:0xFFFFF3, .selection:0x0A246A, .row:0xF5F4EF, .focus:0x356CB4, .todaySurface:0xEFF5FF, .selectedSurface:0xE7EFFB, .grid:0xC8C6C0, .timeMarker:0xBD3345]
        case .pink:
            hex = [.face:0xF3D7E4, .light:0xFFFFFF, .shadow:0xA56D89, .dark:0x733953, .ink:0x3B1F2D, .muted:0x735365, .navy:0x7F2450, .blue:0xECA8CA, .paper:0xFFF8FC, .selection:0x7F2450, .row:0xFFF3F8, .focus:0xB02768, .todaySurface:0xFBE1ED, .selectedSurface:0xF6D0E3, .grid:0xD6AFBF, .timeMarker:0xAD204D]
        }
        return hex.mapValues(color)
    }
    private static func value(_ token: Token) -> NSColor { (appearance == .classic ? classic : pink)[token]! }
    public static var face: NSColor { value(.face) }
    public static var light: NSColor { value(.light) }
    public static var shadow: NSColor { value(.shadow) }
    public static var dark: NSColor { value(.dark) }
    public static var ink: NSColor { value(.ink) }
    public static var muted: NSColor { value(.muted) }
    public static var navy: NSColor { value(.navy) }
    public static var blue: NSColor { value(.blue) }
    public static var paper: NSColor { value(.paper) }
    public static var selection: NSColor { value(.selection) }
    public static var row: NSColor { value(.row) }
    public static var focus: NSColor { value(.focus) }
    public static var todaySurface: NSColor { value(.todaySurface) }
    public static var selectedSurface: NSColor { value(.selectedSurface) }
    public static var grid: NSColor { value(.grid) }
    public static var timeMarker: NSColor { value(.timeMarker) }

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
    public var edge: ClassicTheme.Edge = .raised { didSet { needsDisplay = true } }
    public var fill: NSColor = ClassicTheme.face { didSet { needsDisplay = true } }
    private let surface = ClassicSurface()
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public override func layout() {
        super.layout()
        needsDisplay = true
    }

    public override func updateLayer() {
        surface.update(layer, bounds: bounds, fill: fill, edge: edge)
    }

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
