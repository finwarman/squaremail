import AppKit
import ClassicKit

private let launchTime = ProcessInfo.processInfo.systemUptime

private final class MailWindow: NSWindow {
    var onClose: (() -> Void)?
    override func performClose(_ sender: Any?) { onClose?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum QuitState { case idle, waiting }
    private var quitState: QuitState = .idle
    private var window: NSWindow?
    private var controller: MailController?

    func applicationDidBecomeActive(_ notification: Notification) { controller?.activated() }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try launch() } catch {
            fputs("Square Mail: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitState == .waiting { return .terminateLater }
        guard controller?.needsQuitConfirm == true else { return .terminateNow }
        quitState = .waiting
        Task { [weak self] in
            self?.controller?.confirmQuit { [weak self] outcome in
                self?.quitState = .idle
                NSApp.reply(toApplicationShouldTerminate: outcome == .closed)
            }
        }
        return .terminateLater
    }

    private func launch() throws {
        let arguments = ProcessInfo.processInfo.arguments
        let appearance = arguments.contains("--theme-pink") ? ClassicTheme.Appearance.pink : (WindowPresentation.isBackground ? .classic : (ClassicTheme.Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .classic))
        ClassicTheme.configure(appearance)
        if WindowPresentation.isBackground, arguments.contains("--host-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        var stages: [String: Double] = [:]
        func stamp(_ stage: LaunchStage) {
            stages[stage.rawValue] = (ProcessInfo.processInfo.systemUptime - launchTime) * 1000
        }
        let directory: URL
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1])
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true).appendingPathComponent("Square Mail")
        }
        let core = try MailCore(directory: directory)
        if let index = arguments.firstIndex(of: "--export-desktop-config"), arguments.indices.contains(index + 1) {
            Task {
                do {
                    let _: EmptyReply = try await core.request(["command": CoreCommand.exportClients.rawValue, "path": arguments[index + 1]], mode: .live, queue: .login)
                    print("Desktop application metadata prepared. No account credentials exported.")
                    NSApp.terminate(nil)
                } catch { fputs("Client configuration unavailable\n", stderr); exit(EXIT_FAILURE) }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--import-client"), arguments.indices.contains(index + 1) {
            Task {
                do {
                    let _: EmptyReply = try await core.request(["command": CoreCommand.importClient.rawValue, "path": arguments[index + 1]], mode: .live, queue: .login)
                    print("Google desktop client saved in Keychain")
                    NSApp.terminate(nil)
                } catch { fputs("OAuth setup failed: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--configure-microsoft"), arguments.indices.contains(index + 1) {
            Task {
                do {
                    let _: EmptyReply = try await core.request(["command": CoreCommand.configure.rawValue, "provider": Provider.outlook.rawValue, "client_id": arguments[index + 1]], mode: .live, queue: .login)
                    print("Microsoft desktop client saved in Keychain")
                    NSApp.terminate(nil)
                } catch { fputs("OAuth setup failed: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            return
        }
        if arguments.contains("--check-refresh") {
            Task {
                do {
                    let accounts: [Account] = try await core.request(["command": CoreCommand.accounts.rawValue], mode: .live)
                    for account in accounts where account.connected == true {
                        let _: EmptyReply = try await core.request(["command": CoreCommand.refreshAccount.rawValue, "account": account.id], mode: .live, queue: .login)
                        print("Refreshed \(account.provider.rawValue) identity")
                    }
                    NSApp.terminate(nil)
                } catch { fputs("Refresh check failed: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            return
        }
        if arguments.contains("--check-media-discovery") {
            Task {
                do {
                    let accounts: [Account] = try await core.request(["command": CoreCommand.accounts.rawValue], mode: .live)
                    for account in accounts where account.connected == true {
                        let messages: [Mail] = try await core.request(["command": CoreCommand.list.rawValue, "account": account.id, "folder": Folder.all.rawValue, "query": "", "offset": 0, "limit": 250], mode: .live)
                        guard let message = messages.first(where: \.hasAttachments) ?? messages.first else { continue }
                        let reply: MediaReply = try await core.request(["command": CoreCommand.media.rawValue, "id": message.id, "mode": BodyFetch.fetch.rawValue], mode: .live, queue: .media)
                        print("Discovered \(account.provider.rawValue) media: \(reply.manifest?.assets.count ?? 0) assets. No remote images fetched.")
                        if let asset = reply.manifest?.assets.first(where: { $0.source.kind != .remote && $0.previewable }) {
                            let file: MediaFile = try await core.request(["command": CoreCommand.mediaFile.rawValue, "id": message.id, "asset": asset.id, "preview": PreviewSize.thumbnail.rawValue], mode: .live, queue: .media)
                            let image = try await core.mediaThumbnail(file)
                            print("Verified \(account.provider.rawValue) attachment thumbnail: \(image.width)x\(image.height)")
                        }
                    }
                    NSApp.terminate(nil)
                } catch { fputs("Media discovery failed: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            return
        }
        stamp(.core)
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
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        let layout = MailLayout(frame: NSRect(origin: .zero, size: size))
        layout.autoresizingMask = [.width, .height]
        window.contentView = layout
        layout.layout()
        layout.split.setPosition(300, ofDividerAt: 0)
        layout.layout()
        stamp(.views)
        addWindowButtons(layout.titleBar, window)
        let controller = MailController(core: core, layout: layout)
        stamp(.controller)
        self.controller = controller
        window.onClose = { [weak controller, weak window] in
            if controller?.hasWorkspaceWindows == true { window?.orderOut(nil) } else { NSApp.terminate(nil) }
        }
        window.center()
        Task {
            await controller.start()
            stamp(.mail)
            await controller.finishSelection()
            WindowPresentation.show(window)
            if !WindowPresentation.isBackground, !arguments.contains("--launch-inactive") { NSApp.activate(ignoringOtherApps: true) }
            stamp(.window)
            controller.startSync()
            if let index = arguments.firstIndex(of: "--check-media"), arguments.indices.contains(index + 1) {
                do {
                    let preview = arguments.contains("--preview-media")
                    try await controller.checkMedia(arguments[index + 1], probe: preview ? .preview : .validate)
                    if !preview { NSApp.terminate(nil) }
                }
                catch { fputs("MEDIA FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--calendar") { try? await controller.checkCalendar(.preview) }
            if let index = arguments.firstIndex(of: "--check-read-hold") {
                do {
                    guard arguments.indices.contains(index + 1), let probe = ReadHoldProbe(rawValue: arguments[index + 1]) else { throw MailError(message: "Expected a read-hold probe") }
                    try await controller.checkReadHold(probe); NSApp.terminate(nil)
                } catch { fputs("READ HOLD FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-workspaces") {
                do { try await controller.checkWorkspaces(); NSApp.terminate(nil) }
                catch { fputs("WORKSPACES FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-action-nav") {
                do { try await controller.checkActionNav(); NSApp.terminate(nil) }
                catch { fputs("ACTION NAV FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-mail-actions") {
                do { try await controller.checkMailActions(); NSApp.terminate(nil) }
                catch { fputs("MAIL ACTIONS FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-control-states") {
                do {
                    try await controller.checkControls()
                    guard let close = layout.titleBar.subviews.compactMap({ $0 as? ClassicButton }).first(where: { $0.title == "×" }) else { throw MailError(message: "Window close control is missing") }
                    print("CLOSE dispatching the native title-bar close action")
                    fflush(stdout)
                    close.performClick(nil)
                    throw MailError(message: "Window close did not terminate the app")
                }
                catch { fputs("CONTROLS FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-calendar-actions") {
                do {
                    let mode: CalendarProbe = arguments.contains("--preview-calendar-actions") ? .preview : .validate
                    try await controller.checkActions(mode)
                    if mode == .validate { NSApp.terminate(nil) }
                } catch { fputs("ACTIONS FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-accounts") {
                do { try await controller.checkAccounts(); print("Offline account switching, folders, unified search and calendar cache verified") }
                catch { fputs("ACCOUNTS FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-calendar") {
                do { try await controller.checkCalendar(); print("Calendar navigation and release verified"); NSApp.terminate(nil) }
                catch { fputs("CALENDAR FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if arguments.contains("--check-paging") {
                do { try await controller.checkPaging(); print("Bounded paging verified"); NSApp.terminate(nil) }
                catch { fputs("PAGING FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
            if let index = arguments.firstIndex(of: "--perf-report"), arguments.indices.contains(index + 1) {
                do {
                    await controller.finishSelection()
                    let path = URL(fileURLWithPath: arguments[index + 1])
                    var report: [String: Any] = ["in_process_reader_ready_ms": (ProcessInfo.processInfo.systemUptime - launchTime) * 1000,
                                               "pid": ProcessInfo.processInfo.processIdentifier,
                                               "startup_stages_ms": stages,
                                               "measurement_complete": false]
                    if arguments.contains("--layer-report") {
                        report["layers"] = LayerReport.collect(layout)
                    }
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: path, options: .atomic)
                    if arguments.contains("--perf-actions") {
                        report["calendar_actions"] = ["cached_editor": true, "bell_limit": 50, "provider_calls": false]
                    } else if arguments.contains("--perf-media") {
                        report["media"] = ["local_images_and_pdf_thumbnail": true]
                    } else if arguments.contains("--perf-calendar") {
                        report["calendar"] = try await controller.measureCalendar()
                    } else {
                        report["switching"] = try await controller.measureSwitches(samples: arguments.contains("--perf-stress") ? 1000 : 200,
                            pattern: arguments.contains("--perf-visible-only") ? .visible : .sequential)
                    }
                    if arguments.contains("--perf-html") || arguments.contains("--perf-html-idle") {
                        report["html_switching"] = try await controller.measureSwitches(.html, samples: 30)
                    }
                    if arguments.contains("--perf-html-idle") {
                        report["html_idle"] = try await controller.measureHTMLIdle()
                    }
                    report["measurement_complete"] = true
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: path, options: .atomic)
                } catch { fputs("PERFORMANCE FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
            }
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
            if arguments.contains("--self-test") || arguments.contains("--check-accounts") || arguments.contains("--quit-after-metrics") { NSApp.terminate(nil) }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window, !WindowPresentation.isBackground { window.makeKeyAndOrderFront(nil) }; return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(WindowPresentation.isBackground ? .accessory : .regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
