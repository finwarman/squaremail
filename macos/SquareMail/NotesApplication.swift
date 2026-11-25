import AppKit
import ClassicKit
import Network

@MainActor
enum NotesAppLauncher {
    static let identifier = "com.finwarman.squaremail.notes"
    static var isNotes: Bool { Bundle.main.bundleIdentifier == identifier }
    private static var bundle: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Square Notes.app") }
    static var available: Bool { FileManager.default.fileExists(atPath: bundle.path) }

    static func open(file: URL?, reply: @escaping (Result<Void, Error>) -> Void) {
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = false
        let finished: (NSRunningApplication?, Error?) -> Void = { _, error in
            Task { @MainActor in if let error { reply(.failure(error)) } else { reply(.success(())) } }
        }
        if let file { NSWorkspace.shared.open([file], withApplicationAt: bundle, configuration: options, completionHandler: finished) }
        else { NSWorkspace.shared.openApplication(at: bundle, configuration: options, completionHandler: finished) }
    }
}

// This entry creates only Notes. Mail, Calendar, OAuth and their schedulers stay absent.
@MainActor
final class NotesAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var core: MailCore?
    private var backup: NotesBackupService?
    private var notes: NotesWindow?
    private var pendingFile: URL?
    private var quitting = false
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private let preferences = UserDefaults(suiteName: "com.finwarman.squaremail")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = ProcessInfo.processInfo.arguments
            let appearance = args.contains("--theme-pink") ? ClassicTheme.Appearance.pink : (WindowPresentation.isBackground ? .classic : (ClassicTheme.Appearance(rawValue: preferences.string(forKey: "appearance") ?? "") ?? .classic))
            ClassicTheme.configure(appearance)
            let directory: URL
            if let index = args.firstIndex(of: "--data-dir"), args.indices.contains(index + 1) { directory = URL(fileURLWithPath: args[index + 1]) }
            else { directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Square Mail") }
            let core = try MailCore(directory: directory); self.core = core
            let backup = NotesBackupService(core: core); self.backup = backup
            backup.onRestored = { [weak self] note in self?.showNotes(); self?.notes?.openNote(note.id) }
            menus(); showNotes()
            if let file = pendingFile { pendingFile = nil; notes?.openFile(file) }
            if args.contains("--check-notes-app") {
                guard WindowPresentation.isBackground else { throw MailError(message: "Notes qualification must stay hidden") }
                Task { [weak self] in
                    do {
                        guard let self, let core = self.core else { throw MailError(message: "Notes app did not start") }
                        let prompts = ScriptedEditorPrompts()
                        self.notes?.close()
                        let test = NotesWindow(core: core, prompts: prompts, identity: .standalone); self.notes = test
                        try await test.verifyStandalone(prompts)
                        print("Independent Notes entry, local editor/search, reopen and save-safe close verified without Mail or provider startup")
                        NSApp.terminate(nil)
                    } catch { fputs("NOTES APP FAILED: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
                }
                return
            }
            guard !WindowPresentation.isBackground, !args.contains("--no-sync") else { return }
            monitor.pathUpdateHandler = { [weak backup] path in Task { @MainActor in backup?.setOnline(path.status == .satisfied) } }
            monitor.start(queue: DispatchQueue(label: "com.finwarman.squaremail.notes-network", qos: .utility))
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak backup] _ in Task { @MainActor in backup?.setAwake(name == NSWorkspace.didWakeNotification) } })
            }
            backup.start()
        } catch { fputs("Square Notes: \(error.localizedDescription)\n", stderr); NSApp.terminate(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard core != nil else { pendingFile = urls.first; return }
        showNotes(); if let file = urls.first { notes?.openFile(file) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showNotes(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard let notes, notes.needsClosePrompt else { return .terminateNow }
        quitting = true
        notes.requestClose { [weak self] result in self?.quitting = false; NSApp.reply(toApplicationShouldTerminate: result == .closed) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        monitor.cancel(); backup?.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    @objc private func showNotes() {
        guard let core, let backup else { return }
        if notes == nil {
            let value = NotesWindow(core: core, backup: backup, identity: .standalone)
            value.onClosed = { [weak self] in self?.notes = nil }; notes = value
        }
        notes?.show()
        if !WindowPresentation.isBackground, !ProcessInfo.processInfo.arguments.contains("--launch-inactive") { NSApp.activate(ignoringOtherApps: true) }
    }
    @objc private func today() { showNotes(); notes?.openDaily(Date()) }
    @objc private func newNote() { showNotes(); notes?.newNote() }
    @objc private func saveNote() { notes?.saveCurrent() }
    @objc private func find() { showNotes(); notes?.find() }
    @objc private func search() { showNotes(); notes?.searchAll() }
    @objc private func classic() { choose(.classic) }
    @objc private func pink() { choose(.pink) }
    private func choose(_ value: ClassicTheme.Appearance) {
        if !WindowPresentation.isBackground { preferences.set(value.rawValue, forKey: "appearance") }
        let alert = NSAlert(); alert.messageText = "Appearance saved"; alert.informativeText = "Restart Square Notes and Square Mail to apply the shared appearance."; WindowPresentation.runAlert(alert)
    }
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }
    private func menus() {
        let main = NSMenu(); let app = NSMenu(); let file = NSMenu(); let edit = NSMenu(); let view = NSMenu(); let window = NSMenu()
        app.addItem(withTitle: "About Square Notes", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "Quit Square Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item(file, "Today", #selector(today), "t"); item(file, "New note", #selector(newNote), "n")
        item(file, "Save", #selector(saveNote), "s")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key) }
        let redo = edit.insertItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z", at: 1); redo.keyEquivalentModifierMask = [.command, .shift]
        item(edit, "Find in note", #selector(find), "f"); item(edit, "Search all notes", #selector(search), "F")
        item(view, "Classic appearance", #selector(classic)); item(view, "Pink appearance", #selector(pink))
        item(window, "Notes window", #selector(showNotes))
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for (title, menu) in [("Square Notes", app), ("File", file), ("Edit", edit), ("View", view), ("Window", window)] { main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu }
        NSApp.mainMenu = main; NSApp.windowsMenu = window
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(classic) || item.action == #selector(pink) {
            let selected = ClassicTheme.Appearance(rawValue: preferences.string(forKey: "appearance") ?? "") ?? .classic
            item.state = selected == (item.action == #selector(pink) ? .pink : .classic) ? .on : .off
        }
        if item.action == #selector(saveNote) { return notes?.isOpen == true }
        return true
    }
}
