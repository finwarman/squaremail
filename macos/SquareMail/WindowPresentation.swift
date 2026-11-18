import AppKit

@MainActor
enum WindowPresentation {
    struct Dialog { let title: String; let buttons: [String] }
    private(set) static var lastDialog: Dialog?
    @discardableResult
    static func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if isBackground { lastDialog = Dialog(title: alert.messageText, buttons: alert.buttons.map(\.title)); return .abort }
        return alert.runModal()
    }
    static func runOpen(_ panel: NSOpenPanel) -> NSApplication.ModalResponse {
        if isBackground { lastDialog = Dialog(title: panel.title, buttons: ["Open", "Cancel"]); return .cancel }
        return panel.runModal()
    }
    static var isBackground: Bool { ProcessInfo.processInfo.arguments.contains("--background-ui") }
    static func snapshot(_ view: NSView, name: String) throws {
        let args = ProcessInfo.processInfo.arguments
        guard isBackground, let index = args.firstIndex(of: "--mail-evidence-dir"), args.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: args[index + 1]); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MailError(message: "Native snapshot allocation failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw MailError(message: "Native snapshot encoding failed") }
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    static func show(_ window: NSWindow) {
        // Classic surfaces are light in both palettes, including on a dark macOS desktop.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        if isBackground { window.ignoresMouseEvents = true; window.orderOut(nil); return }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
protocol EditorPrompting {
    func choose(_ alert: NSAlert, window: NSWindow, reply: @escaping (NSApplication.ModalResponse) -> Void)
}
@MainActor
final class EditorPrompter: EditorPrompting {
    func choose(_ alert: NSAlert, window: NSWindow, reply: @escaping (NSApplication.ModalResponse) -> Void) {
        if WindowPresentation.isBackground { reply(WindowPresentation.runAlert(alert)); return }
        alert.beginSheetModal(for: window, completionHandler: reply)
    }
}

@MainActor
final class ScriptedEditorPrompts: EditorPrompting {
    private var reply: ((NSApplication.ModalResponse) -> Void)?
    private(set) var lastTitle = ""
    private(set) var buttons: [String] = []
    private(set) var presentations = 0
    var pending: Bool { reply != nil }
    func choose(_ alert: NSAlert, window: NSWindow, reply: @escaping (NSApplication.ModalResponse) -> Void) {
        precondition(WindowPresentation.isBackground)
        presentations += 1; lastTitle = alert.messageText; buttons = alert.buttons.map(\.title)
        self.reply = reply
    }
    func respond(_ response: NSApplication.ModalResponse) {
        let callback = reply; reply = nil; callback?(response)
    }
}
