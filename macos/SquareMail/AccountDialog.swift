import AppKit
import ClassicKit

@MainActor
final class AccountDialog: NSObject {
    enum Action { case add, disconnect(String), setup }
    struct Input {
        let provider: Provider
        let clientId: String
        let clientSecret: String
    }
    private let provider = NSPopUpButton(frame: .zero)
    private let connectionNote = NSTextField(wrappingLabelWithString: "")
    private weak var signIn: NSButton?
    private var configs: [Provider: ClientConfig] = [:]

    func manage(_ accounts: [Account]) -> Action? {
        let alert = NSAlert()
        alert.messageText = "Mail and calendar accounts"
        alert.informativeText = "Each account has its own cache and browser sign-in. Disconnect removes its saved tokens. Cached mail can remain available offline."
        alert.addButton(withTitle: "Add / reconnect")
        alert.addButton(withTitle: "Disconnect selected")
        alert.addButton(withTitle: "Advanced setup…")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        for account in accounts where account.provider != .local {
            picker.addItem(withTitle: account.email + (account.connected == false ? " (disconnected)" : ""))
            picker.lastItem?.representedObject = account.id
        }
        picker.setAccessibilityLabel("Saved account")
        alert.accessoryView = picker
        let response = WindowPresentation.runAlert(alert)
        if response == .alertFirstButtonReturn { return .add }
        if response == .alertSecondButtonReturn, let id = picker.selectedItem?.representedObject as? String { return .disconnect(id) }
        if response.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue { return .setup }
        return nil
    }

    func run(_ configs: [Provider: ClientConfig]) -> Input? {
        self.configs = configs
        let alert = NSAlert()
        alert.messageText = "Connect Gmail or Outlook"
        alert.informativeText = "Sign in through your browser. Square Mail requests read-only mail and calendar access. Tokens stay in macOS Keychain. Choose another browser account to add a second mailbox."
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 90))
        provider.frame = NSRect(x: 0, y: 56, width: 440, height: 26)
        provider.removeAllItems()
        provider.addItems(withTitles: ["Gmail / Google Workspace", "Outlook.com / Live / Microsoft 365"])
        provider.setAccessibilityLabel("Email provider")
        provider.target = self
        provider.action = #selector(changeProvider)
        connectionNote.frame = NSRect(x: 0, y: 0, width: 440, height: 44)
        connectionNote.font = ClassicTheme.font(11)
        for view in [provider, connectionNote] { form.addSubview(view) }
        alert.accessoryView = form
        signIn = alert.buttons.first
        changeProvider()
        alert.window.initialFirstResponder = provider
        guard WindowPresentation.runAlert(alert) == .alertFirstButtonReturn,
              configs[selectedProvider]?.configured == true else { return nil }
        return Input(provider: selectedProvider, clientId: "", clientSecret: "")
    }
    private var selectedProvider: Provider { provider.indexOfSelectedItem == 0 ? .gmail : .outlook }
    @objc private func changeProvider() {
        let ready = configs[selectedProvider]?.configured == true
        signIn?.isEnabled = ready
        connectionNote.stringValue = ready
            ? "Your browser will open for sign-in. No developer setup is needed."
            : "Provider setup is missing from this build. Use Accounts, Advanced setup, or install the current release."
    }

    func setup() -> Input? {
        let alert = NSAlert()
        alert.messageText = "Advanced provider setup"
        alert.informativeText = "Google: import the downloaded Desktop app JSON. Microsoft: save the Application (client) ID from your Entra app registration. These settings are stored in Keychain and reused for each account."
        alert.addButton(withTitle: "Import Google JSON")
        alert.addButton(withTitle: "Save Microsoft ID")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 25))
        field.placeholderString = "Microsoft Application (client) ID"
        field.setAccessibilityLabel("Microsoft Application client ID")
        alert.accessoryView = field
        let reply = WindowPresentation.runAlert(alert)
        if reply == .alertFirstButtonReturn { return Input(provider: .gmail, clientId: "", clientSecret: "") }
        if reply == .alertSecondButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Input(provider: .outlook, clientId: field.stringValue, clientSecret: "")
        }
        return nil
    }
}
