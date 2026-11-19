import AppKit

struct SparkleState {
    struct Particle { let point: NSPoint; let born: TimeInterval; let side: CGFloat }
    private(set) var particles: [Particle] = []
    private var last: NSPoint?
    private var nextSide: CGFloat = -5
    static let limit = Int(SharedClassicTokens.sparkleMaxParticles)
    static let lifetime = Double(SharedClassicTokens.sparkleLifetimeMs) / 1000

    mutating func clear() { particles.removeAll(keepingCapacity: true); last = nil }
    mutating func expire(at now: TimeInterval) {
        particles.removeAll { now < $0.born || now - $0.born >= Self.lifetime }
    }
    mutating func move(to point: NSPoint, at now: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite, now.isFinite else { clear(); return }
        expire(at: now)
        guard let previous = last else { last = point; return }
        guard hypot(point.x - previous.x, point.y - previous.y) >= SharedClassicTokens.sparkleSpacing else { return }
        last = point
        if particles.count >= Self.limit { particles.removeFirst() }
        particles.append(Particle(point: point, born: now, side: nextSide)); nextSide *= -1
    }
}

private final class SparkleView: NSView {
    var opacity: CGFloat = 1
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let radius = SharedClassicTokens.sparkleRadius * opacity
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        ClassicTheme.selection.withAlphaComponent(opacity).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        path.move(to: NSPoint(x: center.x - radius, y: center.y)); path.line(to: NSPoint(x: center.x + radius, y: center.y))
        path.move(to: NSPoint(x: center.x, y: center.y - radius)); path.line(to: NSPoint(x: center.x, y: center.y + radius))
        path.stroke()
    }
}

/// Window-local, decorative particles. Small reusable views avoid a full-window overlay texture.
public final class ClassicCursorTrail {
    public enum Mode { case disabled, enabled }
    public var mode: Mode = .disabled { didSet { configure() } }
    private weak var root: NSView?
    private var monitor: Any?
    private weak var monitoredWindow: NSWindow?
    private var previousMouseMoves: Bool?
    private var timer: Timer?
    private var model = SparkleState()
    private var views: [SparkleView] = []
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false

    public init() {}
    public func attach(to root: NSView) { let saved = mode; mode = .disabled; self.root = root; mode = saved }
    private var active: Bool {
        mode == .enabled && !sleeping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && root?.window?.isVisible == true && root?.window?.isKeyWindow == true
            && root?.window?.isMiniaturized == false && root?.window?.occlusionState.contains(.visible) == true
            && root?.isHiddenOrHasHiddenAncestor == false && NSApp?.isActive == true
    }
    private func configure() {
        if mode == .disabled {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            for (center, token) in observations { center.removeObserver(token) }
            observations.removeAll(); stop(); views.removeAll()
            if let previousMouseMoves { monitoredWindow?.acceptsMouseMovedEvents = previousMouseMoves }
            previousMouseMoves = nil; monitoredWindow = nil; return
        }
        guard monitor == nil else { if !active { stop() }; return }
        guard let window = root?.window else { return }
        monitoredWindow = window; previousMouseMoves = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.receive(event); return event
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observe(.default, name) { [weak self] in if self?.active != true { self?.stop() } }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in if self?.active != true { self?.stop() } }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true; self?.stop() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        observations.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }))
    }
    private func receive(_ event: NSEvent) {
        guard active, event.window === root?.window, event.type == .mouseMoved, let root else { stop(); return }
        let point = root.convert(event.locationInWindow, from: nil)
        guard root.bounds.contains(point) else { stop(); return }
        model.move(to: point, at: ProcessInfo.processInfo.systemUptime)
        guard !model.particles.isEmpty, timer == nil else { return }
        let timer = Timer(timeInterval: Double(SharedClassicTokens.sparkleFrameMs) / 1000, repeats: true) { [weak self] _ in
            guard let self, self.active else { self?.stop(); return }
            self.model.expire(at: ProcessInfo.processInfo.systemUptime); self.render()
            if self.model.particles.isEmpty { self.timer?.invalidate(); self.timer = nil }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func render() {
        guard let root else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        while views.count < model.particles.count {
            let view = SparkleView(frame: .zero); view.wantsLayer = true; view.layerContentsRedrawPolicy = .onSetNeedsDisplay; view.setAccessibilityElement(false); views.append(view)
        }
        for (index, view) in views.enumerated() {
            guard index < model.particles.count else { view.removeFromSuperview(); continue }
            let particle = model.particles[index]
            let age = CGFloat(min(1, max(0, (now - particle.born) / SparkleState.lifetime)))
            view.opacity = 1 - age
            view.frame = NSRect(x: particle.point.x + particle.side - 4,
                                y: particle.point.y + 8 + age * 10 - 4, width: 8, height: 8)
            if view.superview !== root { root.addSubview(view, positioned: .above, relativeTo: nil) }
            view.needsDisplay = true
        }
    }
    private func stop() {
        timer?.invalidate(); timer = nil; model.clear()
        for view in views { view.removeFromSuperview() }
    }
    deinit {
        for view in views { view.removeFromSuperview() }
        if let previousMouseMoves { monitoredWindow?.acceptsMouseMovedEvents = previousMouseMoves }
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for (center, token) in observations { center.removeObserver(token) }
    }
}
