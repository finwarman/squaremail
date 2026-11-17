import AppKit
import ClassicKit

private let launchTime = ProcessInfo.processInfo.systemUptime

private final class MailWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var controller: MailController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try launch() } catch {
            fputs("Square Mail: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func launch() throws {
        let arguments = ProcessInfo.processInfo.arguments
        let directory: URL
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1])
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true).appendingPathComponent("Square Mail")
        }
        let core = try MailCore(directory: directory)
        let size = NSSize(width: 1400, height: 920)
        let window = MailWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .resizable, .miniaturizable, .closable],
                                backing: .buffered, defer: false)
        self.window = window
        window.title = "Square Mail"
        window.minSize = NSSize(width: 1060, height: 730)
        window.backgroundColor = ClassicTheme.face
        window.appearance = NSAppearance(named: .aqua)
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let layout = MailLayout(frame: NSRect(origin: .zero, size: size))
        layout.autoresizingMask = [.width, .height]
        window.contentView = layout
        layout.layout()
        layout.split.setPosition(300, ofDividerAt: 0)
        layout.layout()
        addWindowButtons(layout.titleBar, window)
        let controller = MailController(core: core, layout: layout)
        self.controller = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await controller.start()
            if arguments.contains("--metrics") {
                do {
                    let ready = (ProcessInfo.processInfo.systemUptime - launchTime) * 1000
                    var metrics = try await controller.measureCache()
                    metrics["in_process_inbox_ready_ms"] = ready
                    let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
                    print("METRICS \(String(decoding: data, as: UTF8.self))")
                } catch { fputs("METRICS FAILED: \(error.localizedDescription)\n", stderr) }
            }
            if arguments.contains("--self-test") {
                do {
                    let results = try await controller.selfTest()
                    let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                } catch {
                    fputs("SELF-TEST FAILED: \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
                // Let native table layout and the selected body finish before capturing the view.
                try? await Task.sleep(for: .milliseconds(500))
                layout.layoutSubtreeIfNeeded()
                if let bitmap = layout.bitmapImageRepForCachingDisplay(in: layout.bounds) {
                    layout.cacheDisplay(in: layout.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                        print("Snapshot: \(arguments[index + 1])")
                    }
                }
            }
            if arguments.contains("--self-test") || arguments.contains("--quit-after-metrics") { NSApp.terminate(nil) }
        }
    }

    private func addWindowButtons(_ title: ClassicTitleBar, _ window: NSWindow) {
        for (index, label) in ["_", "□", "×"].enumerated() {
            let button = ClassicButton(label, style: .title)
            button.frame = NSRect(x: title.bounds.width - 83 + CGFloat(index * 26), y: 5, width: 23, height: 23)
            button.autoresizingMask = [.minXMargin]
            button.onPress = { [weak window] in
                switch index {
                case 0: window?.miniaturize(nil)
                case 1: window?.zoom(nil)
                default: window?.performClose(nil)
                }
            }
            button.setAccessibilityLabel(["Minimize", "Zoom", "Close"][index])
            title.addSubview(button)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
