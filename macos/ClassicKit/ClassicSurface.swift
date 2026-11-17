import AppKit

/// Solid surfaces need geometry, not a full Retina bitmap for every nested panel.
public final class ClassicSurface {
    private let borders = (0..<8).map { _ in CALayer() }

    public init() {}

    public func update(_ layer: CALayer?, bounds: NSRect, fill: NSColor,
                       edge: ClassicTheme.Edge = .raised) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = fill.cgColor
        layer.contents = nil
        guard bounds.width >= 2, bounds.height >= 2 else {
            borders.forEach { $0.isHidden = true }
            CATransaction.commit()
            return
        }
        let frames = [
            NSRect(x: 0, y: 0, width: bounds.width, height: 1),
            NSRect(x: 0, y: 0, width: 1, height: bounds.height),
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1),
            NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height),
            NSRect(x: 1, y: 1, width: bounds.width - 2, height: 1),
            NSRect(x: 1, y: 1, width: 1, height: bounds.height - 2),
            NSRect(x: 1, y: bounds.height - 2, width: bounds.width - 2, height: 1),
            NSRect(x: bounds.width - 2, y: 1, width: 1, height: bounds.height - 2)
        ]
        let colors = edge == .raised
            ? [ClassicTheme.light, ClassicTheme.light, ClassicTheme.dark, ClassicTheme.dark,
               ClassicTheme.face, ClassicTheme.face, ClassicTheme.shadow, ClassicTheme.shadow]
            : [ClassicTheme.shadow, ClassicTheme.shadow, ClassicTheme.light, ClassicTheme.light,
               ClassicTheme.dark, ClassicTheme.dark, ClassicTheme.face, ClassicTheme.face]
        for (index, border) in borders.enumerated() {
            if border.superlayer !== layer { layer.addSublayer(border) }
            border.isHidden = edge == .flat
            border.frame = frames[index]
            border.backgroundColor = colors[index].cgColor
        }
        CATransaction.commit()
    }
}
