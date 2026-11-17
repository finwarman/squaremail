import AppKit
import ClassicKit

@MainActor
final class AccountDialog {
    struct Input {
        let provider: Provider
        let clientId: String
        let clientSecret: String
    }

    func run() -> Input? {
        let alert = NSAlert()
        alert.messageText = "Connect Gmail or Outlook"
        alert.informativeText = "Use your own OAuth app registration for this private preview. Sign-in opens in your browser. Square Mail requests read-only mail access and keeps tokens in macOS Keychain."
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 168))
        let provider = NSPopUpButton(frame: NSRect(x: 110, y: 132, width: 306, height: 26))
        provider.addItems(withTitles: ["Gmail / Google Workspace", "Outlook / Microsoft 365"])
        let client = NSTextField(frame: NSRect(x: 110, y: 94, width: 306, height: 24))
        client.placeholderString = "OAuth client ID"
        client.setAccessibilityLabel("OAuth client ID")
        let secret = NSSecureTextField(frame: NSRect(x: 110, y: 56, width: 306, height: 24))
        secret.placeholderString = "Google desktop secret, if required"
        secret.setAccessibilityLabel("Optional Google desktop client secret")
        for (label, y) in [("Provider:", 136), ("Client ID:", 98), ("Client secret:", 60)] {
            let field = NSTextField(labelWithString: label)
            field.frame = NSRect(x: 0, y: y, width: 104, height: 19)
            field.font = ClassicTheme.font(11)
            form.addSubview(field)
        }
        let note = NSTextField(wrappingLabelWithString: "Google: Desktop app. Microsoft: public desktop client, with http://localhost/callback registered. See docs/accounts.md.")
        note.frame = NSRect(x: 0, y: 0, width: 420, height: 42)
        note.font = ClassicTheme.font(10)
        for view in [provider, client, secret, note] { form.addSubview(view) }
        alert.accessoryView = form
        alert.window.initialFirstResponder = client
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let id = client.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return Input(provider: provider.indexOfSelectedItem == 0 ? .gmail : .outlook,
                     clientId: id, clientSecret: secret.stringValue)
    }
}
