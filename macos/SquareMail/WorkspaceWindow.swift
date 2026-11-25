import AppKit
import ClassicKit

enum WorkspaceExposure { case visible, hidden }

@MainActor
final class WorkspaceWindow: NSObject, NSWindowDelegate {
    let body = NSView()
    let window: NSWindow
    private let caption = ClassicTitleBar()
    private(set) var isOpen = false
    var onCloseRequest: (() -> Void)?
    var onClosed: (() -> Void)?
    var onExposure: ((WorkspaceExposure) -> Void)?

    init(title: String, size: NSSize, minimum: NSSize, icon: ClassicIcon = .mail) {
        let panel = WorkspacePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window = panel
        super.init()
        panel.minSize = minimum; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.appearance = NSAppearance(named: .aqua); panel.backgroundColor = ClassicTheme.face
        panel.hasShadow = true; panel.animationBehavior = .none
        panel.onClose = { [weak self] in self?.requestClose() }
        let root = panel.contentView!
        let face = ClassicPanel(frame: root.bounds); face.edge = .raised; face.autoresizingMask = [.width, .height]; root.addSubview(face)
        caption.frame = NSRect(x: 3, y: size.height - 36, width: size.width - 6, height: 33)
        caption.autoresizingMask = [.width, .minYMargin]; root.addSubview(caption)
        body.frame = NSRect(x: 3, y: 3, width: size.width - 6, height: size.height - 42)
        body.autoresizingMask = [.width, .height]; root.addSubview(body)
        for (index, label) in ["_", "□", "×"].enumerated() {
            let button = ClassicButton(label, style: .title)
            button.frame = NSRect(x: caption.bounds.width - 83 + CGFloat(index * 26), y: 5, width: 23, height: 23)
            button.autoresizingMask = [.minXMargin]
            button.setAccessibilityLabel(["Minimize", "Zoom", "Close"][index])
            button.onPress = { [weak self] in
                guard let self else { return }
                switch index { case 0: window.miniaturize(nil); case 1: window.zoom(nil); default: requestClose() }
            }
            caption.addSubview(button)
        }
        caption.icon = icon; setTitle(title); panel.center()
    }
    func setTitle(_ title: String) { window.title = title; caption.title = title; caption.needsDisplay = true }
    func show() { isOpen = true; if window.isMiniaturized, !WindowPresentation.isBackground { window.deminiaturize(nil) }; WindowPresentation.show(window); updateExposure() }
    func close() { guard isOpen else { return }; window.close(); finishClose() }
    func hideForDock() { guard isOpen else { return }; isOpen = false; onExposure?(.hidden); window.close() }
    func requestClose() { if let onCloseRequest { onCloseRequest() } else { close() } }
    func windowWillClose(_ notification: Notification) { finishClose() }
    private func finishClose() {
        guard isOpen else { return }
        isOpen = false; onExposure?(.hidden); onClosed?()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateExposure() }
    func windowDidMiniaturize(_ notification: Notification) { updateExposure() }
    func windowDidDeminiaturize(_ notification: Notification) { updateExposure() }
    private func updateExposure() {
        onExposure?(isOpen && (WindowPresentation.isBackground || (window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))) ? .visible : .hidden)
    }
}
private final class WorkspacePanel: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { onClose?() }
}

@MainActor
final class CalendarWindow: NSObject, NSTextFieldDelegate {
    let shell = WorkspaceWindow(title: "Square Mail - Calendar", size: NSSize(width: 1200, height: 800), minimum: NSSize(width: 900, height: 620))
    private let search = NSTextField()
    private let content: CalendarWindowBody
    var onDock: (() -> Void)?
    var isOpen: Bool { shell.isOpen }
    init(view: CalendarView, sidebar: CalendarSidebar) {
        content = CalendarWindowBody(view: view, sidebar: sidebar, search: search)
        super.init()
        search.delegate = self; search.font = ClassicTheme.font(12)
        search.placeholderString = "Search events (⌘F)"; search.stringValue = view.state.query
        search.setAccessibilityLabel("Search calendar window")
        content.frame = shell.body.bounds; content.autoresizingMask = [.width, .height]; shell.body.addSubview(content)
        content.dock.onPress = { [weak self] in self?.onDock?() }
    }
    func show() { shell.show(); content.needsLayout = true; content.layoutSubtreeIfNeeded() }
    func close() { shell.close() }
    func focusSearch() { shell.window.makeFirstResponder(search) }
    func controlTextDidChange(_ notification: Notification) { content.calendar.setQuery(search.stringValue) }
}
private final class CalendarWindowBody: NSView {
    let calendar: CalendarView
    let dock = ClassicButton("Dock to tabs")
    private let sidebar: CalendarSidebar
    private let search: NSTextField
    override var isFlipped: Bool { true }
    init(view: CalendarView, sidebar: CalendarSidebar, search: NSTextField) {
        calendar = view; self.sidebar = sidebar; self.search = search
        super.init(frame: .zero)
        for child in [sidebar, view, search, dock] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("Use init(view:sidebar:search:)") }
    override func layout() {
        super.layout()
        let side: CGFloat = 210
        sidebar.frame = NSRect(x: 0, y: 0, width: side, height: bounds.height)
        search.frame = NSRect(x: side + 8, y: 6, width: bounds.width - side - 144, height: 28)
        dock.frame = NSRect(x: bounds.width - 128, y: 6, width: 120, height: 28)
        calendar.frame = NSRect(x: side + 4, y: 40, width: bounds.width - side - 8, height: max(0, bounds.height - 44))
    }
}
