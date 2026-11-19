import AppKit

public enum ClassicTheme {
    public enum Appearance: String, CaseIterable { case classic, pink }
    public private(set) static var appearance: Appearance = .classic
    // Configure before constructing views. Existing windows retain stored control colors.
    public static func configure(_ value: Appearance) { appearance = value }
    private static var palette: ClassicPalette { appearance == .classic ? SharedClassicTokens.classic : SharedClassicTokens.pink }
    public static var face: NSColor { palette.face }
    public static var light: NSColor { palette.light }
    public static var shadow: NSColor { palette.shadow }
    public static var dark: NSColor { palette.dark }
    public static var ink: NSColor { palette.ink }
    public static var muted: NSColor { palette.muted }
    public static var navy: NSColor { palette.navy }
    public static var blue: NSColor { palette.blue }
    public static var paper: NSColor { palette.paper }
    public static var selection: NSColor { palette.selection }
    public static var row: NSColor { palette.row }
    public static var focus: NSColor { palette.focus }
    public static var todaySurface: NSColor { palette.todaySurface }
    public static var selectedSurface: NSColor { palette.selectedSurface }
    public static var grid: NSColor { palette.grid }
    public static var timeMarker: NSColor { palette.timeMarker }

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
        let blend = SharedClassicTokens.captionGradientBlend / 100
        let start = ClassicTheme.navy.usingColorSpace(.sRGB) ?? ClassicTheme.navy
        let end = ClassicTheme.blue.usingColorSpace(.sRGB) ?? ClassicTheme.blue
        let middle = NSColor(srgbRed: start.redComponent + (end.redComponent - start.redComponent) * blend,
                             green: start.greenComponent + (end.greenComponent - start.greenComponent) * blend,
                             blue: start.blueComponent + (end.blueComponent - start.blueComponent) * blend, alpha: 1)
        let gradient = NSGradient(colors: [ClassicTheme.navy, ClassicTheme.navy, middle, ClassicTheme.blue],
                                  atLocations: [0, SharedClassicTokens.captionGradientStart / 100, SharedClassicTokens.captionGradientMiddle / 100, 1], colorSpace: .sRGB)
        gradient?.draw(in: bounds, angle: 0)
        drawGlitter()
        ClassicIcon.mail.draw(in: NSRect(x: 6, y: 6, width: 20, height: 20))
        ClassicTheme.text(title, in: NSRect(x: 34, y: 7, width: bounds.width - 132, height: 22),
                          size: 14, color: .white, weight: .bold)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.zoom(nil); return }
        window?.performDrag(with: event)
    }

    private func drawGlitter() {
        // Static edge flecks leave the caption's text band clear. No texture or repaint timer.
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let width = min(bounds.width, SharedClassicTokens.captionGlitterPeriod * 128)
        for mark in SharedClassicTokens.captionGlitter {
            NSColor.white.withAlphaComponent(SharedClassicTokens.captionGlitterOpacity * mark.alpha / 10000).setFill()
            let y = mark.y < SharedClassicTokens.captionHeight / 2 ? mark.y : bounds.height - SharedClassicTokens.captionHeight + mark.y
            for tile in stride(from: CGFloat.zero, to: width, by: SharedClassicTokens.captionGlitterPeriod) {
                NSRect(x: bounds.minX + tile + mark.x, y: bounds.minY + y, width: mark.w, height: mark.h).fill()
            }
        }
    }
}
