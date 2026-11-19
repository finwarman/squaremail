import AppKit

// Native launch services own activation. No updater loop or download runs in Mail.
@MainActor
enum AppUpdates {
    private static let managerID = "dev.f1nb0.launcher"
    private static let downloadURL = "https://f1nb0.dev/apps/"

    static func open() {
        let identifier = managerID
        Task {
            let manager = await Task.detached {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            }.value
            guard let manager else { openDownloads(); return }
            NSWorkspace.shared.openApplication(at: manager, configuration: .init()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in openDownloads() }
            }
        }
    }

    private static func openDownloads() {
        guard let url = URL(string: downloadURL), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Could not open app updates"
            alert.informativeText = "Visit f1nb0.dev/apps/ to download f1nb0 Apps."
            WindowPresentation.runAlert(alert)
            return
        }
    }
}
