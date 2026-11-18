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
    private let client = NSTextField(frame: .zero)
    private var configs: [Provider: ClientConfig] = [:]

    func manage(_ accounts: [Account]) -> Action? {
        let alert = NSAlert()
        alert.messageText = "Mail and calendar accounts"
        alert.informativeText = "Each account has its own cache and browser sign-in. Disconnect removes its saved tokens. Cached mail can remain available offline."
        alert.addButton(withTitle: "Add / reconnect")
        alert.addButton(withTitle: "Disconnect selected")
        alert.addButton(withTitle: "OAuth setup")
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
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 170))
        provider.frame = NSRect(x: 110, y: 132, width: 326, height: 26)
        provider.removeAllItems()
        provider.addItems(withTitles: ["Gmail / Google Workspace", "Outlook.com / Live / Microsoft 365"])
        provider.target = self
        provider.action = #selector(changeProvider)
        client.frame = NSRect(x: 110, y: 94, width: 326, height: 24)
        client.placeholderString = "OAuth client ID, or configure in OAuth setup"
        client.setAccessibilityLabel("OAuth client ID")
        let secret = NSSecureTextField(frame: NSRect(x: 110, y: 56, width: 326, height: 24))
        secret.placeholderString = "Leave empty when a Google client file is saved"
        secret.setAccessibilityLabel("Optional Google desktop client secret")
        for (label, y) in [("Provider:", 136), ("Client ID:", 98), ("Client secret:", 60)] {
            let field = NSTextField(labelWithString: label)
            field.frame = NSRect(x: 0, y: y, width: 104, height: 19)
            field.font = ClassicTheme.font(11)
            form.addSubview(field)
        }
        let note = NSTextField(wrappingLabelWithString: "Google: Desktop app with Gmail and Calendar enabled. Microsoft: public desktop client allowing both personal and work accounts, with http://localhost/callback registered.")
        note.frame = NSRect(x: 0, y: 0, width: 440, height: 42)
        note.font = ClassicTheme.font(10)
        for view in [provider, client, secret, note] { form.addSubview(view) }
        alert.accessoryView = form
        changeProvider()
        alert.window.initialFirstResponder = provider
        guard WindowPresentation.runAlert(alert) == .alertFirstButtonReturn else { return nil }
        return Input(provider: selectedProvider, clientId: client.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret: secret.stringValue)
    }
    private var selectedProvider: Provider { provider.indexOfSelectedItem == 0 ? .gmail : .outlook }
    @objc private func changeProvider() { client.stringValue = configs[selectedProvider]?.clientId ?? "" }

    func setup() -> Input? {
        let alert = NSAlert()
        alert.messageText = "Private preview OAuth setup"
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
