import AppKit
import Quartz

@MainActor
final class DocumentPreview: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var preview: QLPreviewView?

    func show(_ file: MediaFile, name: String) throws {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        guard let view = QLPreviewView(frame: panel.contentView!.bounds, style: .normal) else { throw MailError(message: "Native document preview is unavailable") }
        panel.title = name
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        view.autoresizingMask = [.width, .height]
        view.shouldCloseWithWindow = false
        panel.contentView = view
        view.previewItem = URL(fileURLWithPath: file.path) as NSURL
        window = panel
        preview = view
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        preview?.previewItem = nil
        preview?.close()
        preview = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        preview?.previewItem = nil
        preview?.close()
        preview = nil
        window?.delegate = nil
        window = nil
    }
}
