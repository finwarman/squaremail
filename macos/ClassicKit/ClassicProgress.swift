import AppKit

public final class ClassicProgress: NSView {
    public enum State: Equatable {
        case idle, indeterminate
        case determinate(completed: Int, total: Int)
    }
    public var state: State = .idle { didSet { needsDisplay = true; updateAnimation() } }
    private var timer: Timer?
    private var phase = 0
    private var sleeping = false
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    public override var isFlipped: Bool { true }
    public override var isHidden: Bool { didSet { updateAnimation() } }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification] {
            observe(.default, name: name) { [weak self] in self?.updateAnimation() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observe(center, name: NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true; self?.updateAnimation() }
        observe(center, name: NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false; self?.updateAnimation() }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping () -> Void) {
        observations.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }))
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    public override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    private func updateAnimation() {
        let active = state == .indeterminate && !sleeping && !isHiddenOrHasHiddenAncestor && window?.isVisible == true && window?.isMiniaturized == false && NSApp?.isActive == true
        guard active else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            updateAnimation()
            guard self.timer != nil else { return }
            phase = (phase + 1) % 24; needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    public override func accessibilityValue() -> Any? {
        switch state {
        case .idle: return "Idle"
        case .indeterminate: return "Working"
        case let .determinate(completed, total): return total > 0 ? "\(max(0, min(completed, total))) of \(total)" : "Working"
        }
    }
    public override func draw(_ dirtyRect: NSRect) {
        let idle = state == .idle
        (idle ? ClassicTheme.face : ClassicTheme.light).setFill(); bounds.fill(); ClassicTheme.bevel(bounds, edge: .sunken)
        let inner = bounds.insetBy(dx: 3, dy: 3)
        guard inner.width > 0, inner.height > 0 else { return }
        let count = max(1, Int(inner.width / 10))
        let filled: Int
        switch state {
        case .idle: filled = count
        case .indeterminate: filled = count
        case let .determinate(completed, total): filled = total > 0 ? Int(ceil(Double(max(0, min(completed, total))) / Double(total) * Double(count))) : 0
        }
        (idle ? ClassicTheme.shadow.withAlphaComponent(0.35) : ClassicTheme.selection).setFill()
        for index in 0..<filled {
            if state == .indeterminate && (index + phase) % 8 >= 3 { continue }
            NSRect(x: inner.minX + CGFloat(index) * 10, y: inner.minY, width: min(8, inner.maxX - inner.minX - CGFloat(index) * 10), height: inner.height).fill()
        }
    }
    deinit {
        timer?.invalidate()
        for (center, observer) in observations { center.removeObserver(observer) }
    }
}
