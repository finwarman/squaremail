import AppKit

private enum PixelFill { case outline, solid }

public enum ClassicIcon {
    case mail, inbox, sent, draft, trash, folder, search, sync, star, account, html, text, attach, settings, calendar

    public func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 16, y: rect.height / 16)
        context.setShouldAntialias(false)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: UInt32) {
            ClassicTheme.color(color).setFill()
            NSRect(x: x, y: y, width: w, height: h).fill()
        }
        func line(_ points: [NSPoint], _ color: UInt32, fill: PixelFill = .outline) {
            let path = NSBezierPath()
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            ClassicTheme.color(color).setStroke()
            ClassicTheme.color(color).setFill()
            if fill == .solid { path.close(); path.fill() } else { path.lineWidth = 1; path.stroke() }
        }
        switch self {
        case .mail, .inbox, .sent:
            box(1, 4, 14, 10, 0x333333)
            box(2, 5, 12, 8, 0xFFF6C5)
            box(2, 5, 12, 1, 0xFFFFFF)
            line([.init(x: 2, y: 5), .init(x: 8, y: 10), .init(x: 14, y: 5)], 0x9F8744)
            line([.init(x: 2, y: 13), .init(x: 6, y: 9)], 0xC6AB5B)
            line([.init(x: 14, y: 13), .init(x: 10, y: 9)], 0xC6AB5B)
            if self == .inbox {
                box(5, 0, 5, 5, 0x2384B5)
                line([.init(x: 3, y: 3), .init(x: 12, y: 3), .init(x: 7.5, y: 8)], 0x00608E, fill: .solid)
                box(6, 0, 2, 4, 0x8CE0EF)
            }
            if self == .sent {
                line([.init(x: 8, y: 0), .init(x: 15, y: 5), .init(x: 10, y: 6), .init(x: 9, y: 11)], 0x288B43, fill: .solid)
            }
        case .folder, .draft:
            box(1, 4, 14, 10, 0x85650D)
            box(2, 2, 6, 3, 0x85650D)
            box(3, 3, 4, 3, 0xFFE18A)
            box(2, 5, 12, 8, 0xEBC35A)
            box(2, 5, 12, 1, 0xFFF0AB)
            box(3, 7, 11, 6, 0xFFD676)
            if self == .draft {
                line([.init(x: 8, y: 13), .init(x: 11, y: 4), .init(x: 14, y: 3), .init(x: 12, y: 12)], 0x274EA1, fill: .solid)
            }
        case .search:
            box(10, 10, 2, 2, 0x333333)
            box(11, 11, 3, 3, 0x315E9B)
            box(13, 13, 2, 2, 0x333333)
            ClassicTheme.color(0x333333).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 11, height: 11)).fill()
            ClassicTheme.color(0xA6DFEE).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 9, height: 9)).fill()
            box(4, 3, 4, 1, 0xFFFFFF)
        case .sync:
            line([.init(x: 3, y: 7), .init(x: 4, y: 3), .init(x: 10, y: 2), .init(x: 13, y: 5)], 0x247BB6)
            line([.init(x: 10, y: 5), .init(x: 15, y: 6), .init(x: 14, y: 1)], 0x247BB6, fill: .solid)
            line([.init(x: 13, y: 9), .init(x: 12, y: 13), .init(x: 6, y: 14), .init(x: 3, y: 11)], 0x247BB6)
            line([.init(x: 6, y: 11), .init(x: 1, y: 10), .init(x: 2, y: 15)], 0x247BB6, fill: .solid)
        case .star:
            line([.init(x: 8, y: 1), .init(x: 10, y: 6), .init(x: 15, y: 6), .init(x: 11, y: 10),
                  .init(x: 13, y: 15), .init(x: 8, y: 12), .init(x: 3, y: 15), .init(x: 5, y: 10),
                  .init(x: 1, y: 6), .init(x: 6, y: 6)], 0xD4A520, fill: .solid)
            box(7, 5, 2, 5, 0xFFE98D)
        case .trash:
            box(4, 4, 9, 11, 0x777777); box(5, 5, 7, 9, 0xD7DCDD)
            box(3, 3, 11, 2, 0x737D82); box(6, 1, 5, 2, 0x737D82)
            box(6, 6, 1, 7, 0xFFFFFF); box(9, 6, 1, 7, 0x919C9F)
        case .account:
            box(1, 2, 14, 12, 0x2B537A); box(2, 3, 12, 10, 0xE8F0F5)
            box(4, 5, 4, 4, 0xE7B47C); box(3, 9, 6, 3, 0x317AC0)
            box(10, 5, 3, 1, 0x777777); box(10, 8, 3, 1, 0x777777)
        case .calendar:
            box(1, 2, 14, 13, 0x404040); box(2, 3, 12, 11, 0xFFFFFF)
            box(2, 3, 12, 3, 0x0A246A)
            box(4, 1, 2, 4, 0x808080); box(10, 1, 2, 4, 0x808080)
            for y in [8, 11] { for x in [4, 7, 10] { box(CGFloat(x), CGFloat(y), 2, 2, 0x6085B3) } }
        case .html, .text, .attach, .settings:
            box(3, 1, 10, 14, 0x737373); box(4, 2, 8, 12, 0xFFFFFF)
            let color: UInt32 = self == .html ? 0x246CB0 : 0x6D6D6D
            for y in stride(from: 5, to: 12, by: 3) { box(5, CGFloat(y), 6, 1, color) }
        }
        context.restoreGState()
    }
}
