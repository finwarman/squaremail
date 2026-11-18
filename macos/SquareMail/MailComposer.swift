import AppKit
import ClassicKit
import MessageText

@MainActor
final class MailComposer: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    enum CloseResult { case closed, cancelled }
    private enum Phase { case closed, loading, editing, saving, prompting }
    private let core: MailCore
    private let prompts: EditorPrompting
    private var phase: Phase = .closed
    private var window: NSPanel?
    private var task: Task<Void, Never>?
    private var autosave: Task<Void, Never>?
    private var generation = 0
    private var draft: MailDraft?
    private var editVersion = 0
    private var savedVersion = 0
    private var accounts: [Account] = []
    private let sender = NSPopUpButton(frame: .zero)
    private let to = NSTextField(); private let cc = NSTextField(); private let bcc = NSTextField(); private let subject = NSTextField()
    private let text = NSTextView(usingTextLayoutManager: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let save = ClassicButton("Save draft")
    private let send = ClassicButton("Send")
    private let cancel = ClassicButton("Close")
    var onSaved: (() -> Void)?
    var onQueued: (() -> Void)?
    var onStatus: ((String) -> Void)?
    init(core: MailCore, prompts: EditorPrompting? = nil) { self.core = core; self.prompts = prompts ?? EditorPrompter(); super.init() }
    var needsClosePrompt: Bool { window != nil && (dirty || phase == .saving) }
    private var document: MailDraft? {
        guard var draft else { return nil }
        if draft.kind == .new, let id = sender.selectedItem?.representedObject as? String { draft.account = id }
        let list: (NSTextField) -> [String] = { ($0.currentEditor()?.string ?? $0.stringValue).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        draft.to = list(to); draft.cc = list(cc); draft.bcc = list(bcc)
        draft.subject = subject.currentEditor()?.string ?? subject.stringValue; draft.text = text.string
        return draft
    }
    private var dirty: Bool { editVersion != savedVersion }
    func close() {
        phase = .closed; generation += 1
        task?.cancel(); task = nil; autosave?.cancel(); autosave = nil
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort) }
        window?.delegate = nil; window?.close(); window = nil; draft = nil; editVersion = 0; savedVersion = 0
        text.string = ""; text.undoManager?.removeAllActions()
    }
    func requestClose(_ reply: @escaping (CloseResult) -> Void = { _ in }) {
        if phase == .saving { status.stringValue = "Saving the draft. Please wait before closing."; reply(.cancelled); return }
        if phase == .prompting { reply(.cancelled); return }
        guard dirty, draft != nil, let window else { close(); reply(.closed); return }
        autosave?.cancel()
        let alert = NSAlert(); alert.messageText = "Save this mail draft?"
        alert.informativeText = "Save on this Mac, discard changes since the last save, or keep editing. Nothing is sent by saving a draft."
        alert.addButton(withTitle: "Save draft"); alert.addButton(withTitle: "Discard changes"); alert.addButton(withTitle: "Keep editing")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        transition(.prompting)
        prompts.choose(alert, window: window) { [weak self] response in
            guard let self, self.window === window, phase == .prompting else { reply(.cancelled); return }
            transition(.editing)
            if response == .alertSecondButtonReturn { close(); reply(.closed); return }
            guard response == .alertFirstButtonReturn else { reply(.cancelled); return }
            persist { [weak self] result in
                if result == .closed { self?.close() }
                reply(result)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    func open(_ kind: ComposeKind, account: String, original: String?, mode: BodyFetch, accounts: [Account], seed: MailLinkDraft? = nil) {
        requestClose { [weak self] result in
            guard let self, result == .closed else { return }
            build(accounts); transition(.loading)
            let revision = generation
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let reply: ComposeReply = try await core.request(["command": CoreCommand.compose.rawValue, "account": account, "original": original as Any? ?? NSNull(), "kind": kind.rawValue, "mode": mode.rawValue], mode: .live, queue: mode == .fetch ? .network : .local)
                    guard generation == revision, !Task.isCancelled else { return }
                    var draft = reply.draft
                    if let seed { draft.to = seed.to; draft.cc = seed.cc; draft.subject = seed.subject; draft.text = seed.body }
                    fill(draft)
                    if seed != nil { scheduleSave() }
                    var message = "Drafts save on this Mac. Sending queues a reviewed snapshot."
                    if reply.needsHeaders && kind != .new { message += " Reply metadata is incomplete. Reopen while online before sending a reply." }
                    if reply.attachmentsOmitted { message += " Forward includes text only. Original attachments are omitted." }
                    status.stringValue = message
                } catch {
                    guard generation == revision else { return }
                    transition(.editing); status.stringValue = error.localizedDescription
                }
            }
        }
    }
    func openDraft(_ id: String, accounts: [Account]) {
        requestClose { [weak self] result in
            guard let self, result == .closed else { return }
            build(accounts); transition(.loading)
            let revision = generation
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let draft: MailDraft = try await core.request(["command": CoreCommand.mailDraft.rawValue, "id": id], mode: .live)
                    guard generation == revision else { return }
                    fill(draft); status.stringValue = "Local draft restored. Nothing has been sent."
                } catch { guard generation == revision else { return }; transition(.editing); status.stringValue = error.localizedDescription }
            }
        }
    }
    private func fill(_ draft: MailDraft) {
        self.draft = draft
        for item in sender.itemArray where item.representedObject as? String == draft.account { sender.select(item) }
        to.stringValue = draft.to.joined(separator: ", "); cc.stringValue = draft.cc.joined(separator: ", "); bcc.stringValue = draft.bcc.joined(separator: ", ")
        subject.stringValue = draft.subject; text.string = draft.text
        text.undoManager?.removeAllActions(); editVersion = 0; savedVersion = 0
        transition(.editing)
        window?.makeFirstResponder(draft.kind == .new || draft.kind == .forward ? to : text)
    }
    private func transition(_ value: Phase) {
        phase = value
        let enabled = value == .editing && draft != nil
        for field in [to, cc, bcc, subject] { field.isEnabled = enabled }
        text.isEditable = enabled
        sender.isEnabled = enabled && draft?.kind == .new
        save.isEnabled = enabled; send.isEnabled = enabled; cancel.isEnabled = value != .prompting && value != .saving
    }
    private func build(_ accounts: [Account]) {
        self.accounts = accounts.filter { $0.provider != .local }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Square Mail - Compose"; panel.minSize = NSSize(width: 780, height: 650)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let content = panel.contentView!
        content.wantsLayer = true; content.layer?.backgroundColor = ClassicTheme.face.cgColor
        func field(_ caption: String, _ view: NSView, _ y: CGFloat) {
            let label = NSTextField(labelWithString: caption); label.font = ClassicTheme.font(11)
            label.frame = NSRect(x: 12, y: y + 3, width: 62, height: 21)
            view.setAccessibilityLabel(caption)
            view.frame = NSRect(x: 76, y: y, width: 690, height: 26); view.autoresizingMask = [.width, .minYMargin]
            label.autoresizingMask = [.minYMargin]; content.addSubview(label); content.addSubview(view)
        }
        sender.removeAllItems()
        for account in self.accounts { sender.addItem(withTitle: account.email); sender.lastItem?.representedObject = account.id }
        sender.target = self; sender.action = #selector(changed)
        field("From:", sender, 610); field("To:", to, 576); field("CC:", cc, 542); field("BCC:", bcc, 508); field("Subject:", subject, 474)
        for input in [to, cc, bcc, subject] { input.delegate = self; input.font = ClassicTheme.font(12); input.stringValue = "" }
        for input in [to, cc, bcc] { input.placeholderString = "Email addresses, separated by commas" }
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 106, width: 754, height: 356))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.autoresizingMask = [.width, .height]
        text.setAccessibilityLabel("Mail body")
        text.isRichText = false; text.isEditable = true; text.font = ClassicTheme.font(13); text.textColor = ClassicTheme.ink; text.backgroundColor = .white
        text.frame = NSRect(origin: .zero, size: scroll.contentSize); text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 12, height: 12); text.allowsUndo = true; text.delegate = self
        scroll.documentView = text; content.addSubview(scroll)
        status.frame = NSRect(x: 12, y: 45, width: 754, height: 50); status.font = ClassicTheme.font(10); status.autoresizingMask = [.width]
        content.addSubview(status)
        for (index, button) in [save, send, cancel].enumerated() { button.frame = NSRect(x: 12 + index * 145, y: 9, width: 135, height: 28); content.addSubview(button) }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        save.onPress = { [weak self] in self?.persist() }; send.onPress = { [weak self] in self?.confirmSend() }; cancel.onPress = { [weak self] in self?.requestClose() }
        window = panel; panel.center(); WindowPresentation.show(panel)
    }
    func controlTextDidChange(_ notification: Notification) { scheduleSave() }
    func textDidChange(_ notification: Notification) { scheduleSave() }
    @objc private func changed() { scheduleSave() }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let count = textView.string.utf16.count - affectedCharRange.length + (replacementString?.utf16.count ?? 0)
        if count > 1024 * 1024 { status.stringValue = "Body limit is 1 MiB. Remove text before adding more."; return false }
        return true
    }
    private func scheduleSave() {
        autosave?.cancel()
        guard phase == .editing, draft != nil else { return }
        editVersion += 1
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            self?.persist()
        }
    }
    private func persist(_ reply: @escaping (CloseResult) -> Void = { _ in }) {
        guard phase == .editing, document != nil else { reply(.cancelled); return }
        autosave?.cancel(); window?.makeFirstResponder(nil); transition(.saving)
        let revision = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await storeCurrent()
                guard generation == revision else { return }
                transition(.editing); status.stringValue = "Draft saved on this Mac."; onSaved?(); reply(.closed)
            } catch { guard generation == revision else { return }; transition(.editing); status.stringValue = error.localizedDescription; reply(.cancelled) }
        }
    }
    private func storeCurrent() async throws {
        guard var value = document else { throw MailError(message: "No draft is open") }
        let receipt: DraftReceipt = try await core.request(["command": CoreCommand.saveMailDraft.rawValue, "draft": try value.command()], mode: .live)
        value.revision = receipt.revision; draft = value; savedVersion = editVersion
    }
    private func confirmSend() {
        guard phase == .editing, let value = document, let window else { return }
        autosave?.cancel(); window.makeFirstResponder(nil)
        let alert = NSAlert(); alert.messageText = "Send this email?"
        alert.informativeText = "From: \(accounts.first { $0.id == value.account }?.email ?? "")\nTo: \(value.to.joined(separator: ", "))\nCC: \(value.cc.joined(separator: ", "))\nBCC: \(value.bcc.joined(separator: ", "))\n\nSubject: \(value.subject)\n\nThis queues delivery when online and authorised. Plain text only; original attachments are not included."
        alert.addButton(withTitle: "Queue send"); alert.addButton(withTitle: "Keep editing")
        transition(.prompting)
        prompts.choose(alert, window: window) { [weak self] response in
            guard let self, self.window === window, phase == .prompting else { return }
            transition(.editing)
            guard response == .alertFirstButtonReturn else { return }
            transition(.saving)
            let revision = generation
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await storeCurrent()
                    guard let draft else { return }
                    let _: EmptyReply = try await core.request(["command": CoreCommand.sendMail.rawValue, "id": draft.id, "revision": draft.revision], mode: .live)
                    guard generation == revision else { return }
                    onQueued?(); onStatus?("Email queued. Drafts / outbox shows delivery or consent errors."); close()
                } catch { guard generation == revision else { return }; transition(.editing); status.stringValue = error.localizedDescription }
            }
        }
    }
}

extension MailComposer {
    func verifyControls(_ prompts: ScriptedEditorPrompts, accounts: [Account], original: String) async throws {
        precondition(WindowPresentation.isBackground)
        open(.new, account: "fixture", original: nil, mode: .cached, accounts: accounts)
        await task?.value
        guard phase == .editing, !dirty, to.isEnabled else { throw MailError(message: "Compose did not enter a usable state") }
        to.stringValue = "ada@example.test"; cc.stringValue = "cc@example.test"; bcc.stringValue = "bcc@example.test"
        subject.stringValue = "Offline native draft"; text.string = "Hello\n\n- one\n  - nested\n\n> Earlier\n> > Older\n--------"
        scheduleSave(); await autosave?.value; await task?.value
        if let view = window?.contentView { try WindowPresentation.snapshot(view, name: "compose") }
        guard let saved = draft, saved.revision > 0, !dirty else { throw MailError(message: "Compose autosave did not persist") }
        let stored: MailDraft = try await core.request(["command": CoreCommand.mailDraft.rawValue, "id": saved.id], mode: .live)
        guard stored.text == text.string, stored.bcc == ["bcc@example.test"] else { throw MailError(message: "Draft save changed body/recipients") }
        subject.stringValue = "Unsaved newer subject"; changed()
        window?.performClose(nil)
        guard prompts.pending, phase == .prompting else { throw MailError(message: "Compose close skipped unsaved choices") }
        let count = prompts.presentations; requestClose(); guard prompts.presentations == count else { throw MailError(message: "Repeated compose close duplicated its prompt") }
        prompts.respond(.alertThirdButtonReturn)
        guard phase == .editing, dirty else { throw MailError(message: "Keep editing lost compose fields") }
        send.performClick(nil); prompts.respond(.alertSecondButtonReturn)
        guard phase == .editing, subject.stringValue == "Unsaved newer subject" else { throw MailError(message: "Send cancellation lost draft state") }
        cancel.performClick(nil); prompts.respond(.alertSecondButtonReturn)
        guard window == nil else { throw MailError(message: "Discard did not close compose") }
        openDraft(saved.id, accounts: accounts); await task?.value
        guard subject.stringValue == "Offline native draft" else { throw MailError(message: "Saved draft was overwritten by discarded changes") }
        to.stringValue = "invalid recipient"
        send.performClick(nil); prompts.respond(.alertFirstButtonReturn); await task?.value
        guard phase == .editing, send.isEnabled, !status.stringValue.isEmpty else { throw MailError(message: "Invalid send left compose blocked") }
        to.stringValue = "ada@example.test"
        send.performClick(nil); prompts.respond(.alertFirstButtonReturn); await task?.value
        guard window == nil else { throw MailError(message: "Queued offline send did not close compose") }
        let work: MailWorkspace = try await core.request(["command": CoreCommand.mailWorkspace.rawValue], mode: .live)
        guard work.work.contains(where: { $0.id == saved.id && $0.kind == .outbox && $0.state == .pending }) else { throw MailError(message: "Offline send was not durably queued") }
        let _: EmptyReply = try await core.request(["command": CoreCommand.mailWork.rawValue, "id": saved.id, "kind": MailWorkKind.outbox.rawValue, "choice": MailWorkChoice.cancel.rawValue], mode: .live)
        open(.replyAll, account: "fixture", original: original, mode: .cached, accounts: accounts); await task?.value
        guard to.stringValue.contains("replies@example.test"), cc.stringValue == "cc@example.test", bcc.stringValue.isEmpty else { throw MailError(message: "Reply-all did not preserve reply metadata") }
        close()
        open(.forward, account: "fixture", original: original, mode: .cached, accounts: accounts); await task?.value
        guard to.stringValue.isEmpty, subject.stringValue.hasPrefix("Fwd:"), text.string.contains("> > Previous reply") else { throw MailError(message: "Forward lost nested quote text") }
        close()
    }
}
