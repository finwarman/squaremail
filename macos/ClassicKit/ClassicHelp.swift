import AppKit

// One delayed task and one non-activating window, only while a button is hovered.
@MainActor
final class ClassicHelp {
    static let shared = ClassicHelp()
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?
    private weak var owner: NSView?
    private var observations: [NSObjectProtocol] = []
    private init() {
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.hide() } })
        }
    }
    func show(_ text: String?, from view: NSView) {
        hide()
        guard let text, !text.isEmpty, view.window?.isKeyWindow == true else { return }
        owner = view
        pending = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(Int64(SharedClassicTokens.tooltipDelayMs))) } catch { return }
            guard let self, let view, owner === view, view.window?.isKeyWindow == true else { return }
            let label = NSTextField(wrappingLabelWithString: String(text.prefix(400)))
            label.font = ClassicTheme.font(11); label.textColor = ClassicTheme.ink
            let width: CGFloat = 300
            let height = min(90, max(20, label.sizeThatFits(NSSize(width: width, height: 200)).height))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width + 16, height: height + 12), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: .aqua); panel.backgroundColor = ClassicTheme.face; panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
            label.frame = NSRect(x: 8, y: 6, width: width, height: height); panel.contentView?.addSubview(label)
            guard let window = view.window else { return }
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? anchor
            panel.setFrameOrigin(NSPoint(x: max(screen.minX + 4, min(anchor.midX - width / 2, screen.maxX - width - 20)), y: max(screen.minY + 4, anchor.minY - height - 18)))
            window.addChildWindow(panel, ordered: .above); panel.orderFrontRegardless(); self.panel = panel
        }
    }
    func hide() { pending?.cancel(); pending = nil; if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }; panel = nil; owner = nil }
}
