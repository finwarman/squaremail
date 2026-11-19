import AppKit
import ClassicKit
import MessageText

@MainActor
final class MailController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let core: MailCore
    private let layout: MailLayout
    private let table = NSTableView()
    private var tableHeader: NSTableHeaderView?
    private let sidebar = Sidebar()
    private var messages: [Mail] = []
    private var accounts: [Account] = []
    private var folder: Folder = .inbox
    private var remoteFolder: MailFolder?
    private let coordinator: SyncCoordinator
    private var notifications: NotificationService?
    private var composer: MailComposer?
    private var workspace: MailWorkspacePanel?
    private var mailTask: Task<Void, Never>?
    private let messageMenu = NSMenu(title: "Message")
    private let mailButton = ClassicButton("Mail", icon: .mail, style: .toolbar)
    private let newButton = ClassicButton("New mail", icon: .draft)
    private let replyButton = ClassicButton("Reply", icon: .mail)
    private let replyAllButton = ClassicButton("Reply all", icon: .mail)
    private let forwardButton = ClassicButton("Forward", icon: .sent)
    private let trashButton = ClassicButton("Trash", icon: .trash)
    private let archiveButton = ClassicButton("Archive", icon: .folder)
    private let moveButton = ClassicButton("Move…", icon: .folder)
    private let readButton = ClassicButton("Mark read")
    private let flagButton = ClassicButton("Flag / star")
    private let pinButton = ClassicButton("Pin")
    private let draftsButton = ClassicButton("Drafts / outbox…")
    private var editor: CalendarEditor?
    private var pendingEdits: PendingEdits?
    private let bell = ClassicButton("Alerts", icon: .bell, style: .toolbar)
    private let media: MessageMedia
    private var noticeTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var folderTask: Task<Void, Never>?
    private var calendarRevision = 0
    private let cancelLogin = ClassicButton("Cancel sign-in")
    private var account: String?
    private var mailbox: MailboxMode = .demo
    private var readerMode: ReaderMode = .text
    private var readingLayout: ReadingLayout = .below
    private static let layoutKey = "readingLayout"
    private enum LayoutSave { case save, transient }
    private let splitButton = ClassicButton("Side by side", style: .toggle)
    private var layoutItems: [ReadingLayout: NSMenuItem] = [:]
    private var pendingAppearance = ClassicTheme.appearance
    private var current: Mail?
    private enum ListPhase { case ready, loading }
    private var listPhase: ListPhase = .ready
    private var listRevision = 0
    private var bodyRevision = 0
    private var searchTask: Task<Void, Never>?
    private var pendingCatalog = false
    private var networkAvailable = true
    private var networkReady = false
    private var readingTask: Task<Void, Never>?
    private enum BodyPhase { case ready, loading }
    private var bodyPhase: BodyPhase = .ready
    private var rowViewsMade = 0
    private static let rowReuseID = NSUserInterfaceItemIdentifier("mail-row")
    private static let pageSize = 250
    private var pageOffset = 0
    private var searchScope: MailSearchScope = .folder
    private var searchMode: MailSearchMode = WindowPresentation.isBackground ? .smart : (MailSearchMode(rawValue: UserDefaults.standard.string(forKey: "mailSearchMode") ?? "") ?? .smart)
    private var searchMatch: MailSearchMatch = .none
    private var syncFeedback: Task<Void, Never>?
    private var syncFailureText: String?
    private enum Section { case mail, calendar }
    private var section: Section = .mail
    private var calendarView: CalendarView?
    private var calendarSidebar: CalendarSidebar?
    private var calendarState = CalendarState()
    private struct CalendarCache {
        let sources: [CalendarSource]
        let events: [CalendarEvent]
        let restore: (CalendarView) -> Void
    }
    private var calendarCache: CalendarCache?
    private var idleCalendar: (CalendarView, CalendarSidebar)?
    private var calendarMode: MailboxMode = .demo
    private var calendarIdleTask: Task<Void, Never>?
    private static let calendarIdleDelay: Duration = .seconds(5)
    private var mailSearch = ""
    private let calendarButton = ClassicButton("Calendar", icon: .calendar, style: .toolbar)
    private static let offlineArgs: Set<String> = ["--perf-report", "--self-test", "--check-paging", "--metrics", "--check-calendar", "--check-accounts", "--check-media", "--check-calendar-actions", "--check-control-states", "--check-mail-actions"]
    private let textButton = ClassicButton("Text", icon: .text, style: .segment)
    private let htmlButton = ClassicButton("HTML", icon: .html, style: .segment)
    private let more = ClassicButton("Older")
    private let newer = ClassicButton("Newer")
    private let syncButton = ClassicButton("Refresh", icon: .sync, style: .toolbar)
    private let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM, HH:mm"
        return formatter
    }()

    init(core: MailCore, layout: MailLayout) {
        self.core = core
        self.layout = layout
        self.coordinator = SyncCoordinator(core: core)
        self.media = MessageMedia(core: core, reader: layout.reader)
        super.init()
        let arguments = ProcessInfo.processInfo.arguments
        if Self.offlineArgs.isDisjoint(with: arguments), let value = UserDefaults.standard.string(forKey: Self.layoutKey) {
            readingLayout = ReadingLayout(rawValue: value) ?? .below
        }
        if arguments.contains("--side-by-side") { readingLayout = .right }
        layout.setReadingLayout(readingLayout)
        buildSidebar()
        buildToolbar()
        buildTable()
        buildMenus()
        updateLayoutButtons()
        layout.reader.onLink = { [weak self] url, mail in self?.openReaderLink(url, mail: mail) }
        layout.reader.onLoadImages = { [weak self] mail in
            guard let self else { return }
            self.media.loadImages(mail, mode: self.mailbox)
        }
        layout.reader.onAttachments = { [weak self] mail in
            guard let self else { return }
            self.media.attachments(mail, mode: self.mailbox)
        }
        layout.reader.onPreview = { [weak self] asset, mail in
            guard let self else { return }
            self.media.preview(asset, mail: mail, mode: self.mailbox)
        }
        layout.reader.onOpenPreview = { [weak self] asset, mail in
            guard let self else { return }
            self.media.open(asset, mail: mail, mode: self.mailbox)
        }
        layout.reader.onMediaReset = { [weak self] in self?.media.cancel() }
        layout.reader.onCancelLoad = { [weak self] in
            guard let self else { return }
            media.cancel()
            if bodyPhase == .loading {
                bodyRevision += 1; readingTask?.cancel(); bodyPhase = .ready
                layout.reader.showUnavailable("Loading cancelled. Cached mail remains available.")
                updateMailButtons()
            } else { layout.reader.mediaStatus("Loading cancelled.") }
        }
        layout.reader.onRetryLoad = { [weak self] in
            guard let self, let selected = selectedMail else { return }
            readMessage(selected)
        }
        layout.reader.onImageState = { [weak self] permission in
            guard let self else { return }
            self.layout.header.images = permission
            if self.readerMode == .html { self.layout.statusReader.stringValue = permission == .loaded ? "HTML · IMAGES LOADED" : "HTML · REMOTE OFF" }
        }
        layout.search.delegate = self
        layout.clearSearch.onPress = { [weak self] in self?.clearSearch() }
        layout.searchScope.target = self; layout.searchScope.action = #selector(changeSearchScope)
        layout.fuzzy.state = searchMode == .smart ? .on : .off
        layout.fuzzy.onPress = { [weak self] in
            guard let self else { return }
            searchMode = searchMode == .smart ? .literal : .smart
            if !WindowPresentation.isBackground { UserDefaults.standard.set(searchMode.rawValue, forKey: "mailSearchMode") }
            searchTask?.cancel(); searchTask = Task { await self.loadList() }
        }
        coordinator.onChange = { [weak self] reply in self?.syncChanged(reply) }
        coordinator.onStatus = { [weak self] status in
            guard let self else { return }
            let busy = status == .checking || status == .syncing
            syncButton.isEnabled = !busy
            syncButton.title = status == .checking ? "Checking…" : (status == .syncing ? "Syncing…" : "Refresh")
            syncButton.toolTip = busy ? "Refresh is running. Cached mail and calendars remain usable." : "Check connected mail and calendars now (⌘R). Provider retry limits still apply."
            if busy {
                layout.syncProgress.state = .indeterminate
                if status == .checking {
                    layout.syncCaption.stringValue = "Checking mail and calendars…"
                    syncFailureText = nil
                }
                if layout.syncProgress.isHidden && syncFeedback == nil {
                    syncFeedback = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        self?.layout.syncProgress.isHidden = false
                    }
                }
                return
            }
            syncFeedback?.cancel(); syncFeedback = nil
            layout.syncProgress.state = .idle; layout.syncProgress.isHidden = true
            switch status {
            case .waiting: layout.syncCaption.stringValue = "Check finished at " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            case .offline: layout.syncCaption.stringValue = "Offline. Cached mail stays available; refresh resumes on reconnect."
            case .sleeping: layout.syncCaption.stringValue = "Refresh paused during sleep."
            case .paused: layout.syncCaption.stringValue = "Refresh paused. Connect an account to check for updates."
            case .failed: layout.syncCaption.stringValue = syncFailureText ?? "Refresh needs attention. Try again when connected."
            case .checking, .syncing: break
            }
            layout.syncCaption.toolTip = layout.syncCaption.stringValue
        }
        coordinator.onDetail = { [weak self] reply, count in
            guard let self else { return }
            let account = accounts.first(where: { $0.id == reply.accountId })?.email ?? "Account"
            let phase: String
            switch reply.kind {
            case .catalog: phase = "folder/calendar discovery"
            case .calendar: phase = "calendar updates"
            case .mail, .recentMail: phase = "mail updates"
            case nil: phase = "refresh"
            }
            if let error = reply.error {
                let retry = reply.retryAfter.map { " · retry after " + DateFormatter.localizedString(from: Date().addingTimeInterval(Double($0)), dateStyle: .none, timeStyle: .medium) } ?? " · check Drafts / outbox"
                let caption = account + ": " + error + retry
                syncFailureText = caption; layout.syncCaption.stringValue = caption
            } else { layout.syncCaption.stringValue = "Syncing · \(count) sync steps · last: \(phase), \(account)" }
            layout.syncCaption.toolTip = layout.syncCaption.stringValue
        }
        coordinator.onConnection = { [weak self] connectivity in
            guard let self, self.mailbox == .live else { return }
            let regained = !self.networkAvailable && connectivity == .online
            self.networkAvailable = connectivity == .online
            self.layout.statusMode.stringValue = connectivity == .online ? "LOCAL CACHE" : "OFFLINE CACHE"
            if regained, self.networkReady, self.section == .mail, self.current?.text == nil {
                self.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
            }
        }
    }

    func start() async {
        do {
            let live: [Account] = try await core.request(["command": CoreCommand.accounts.rawValue], mode: .live)
            mailbox = live.isEmpty ? .demo : .live
            if mailbox == .demo {
                let _: EmptyReply = try await core.request(["command": CoreCommand.seedDemo.rawValue], mode: .demo)
            }
            try await loadAccounts()
            await loadList()
        } catch { showError(error) }
    }

    func startSync() {
        guard Self.offlineArgs.isDisjoint(with: ProcessInfo.processInfo.arguments), !ProcessInfo.processInfo.arguments.contains("--no-sync") else { return }
        if mailbox == .live { noticeService().start(accounts) }
        networkReady = true
        coordinator.setActivity(mailbox == .live && accounts.contains(where: { $0.connected == true }) ? .running : .paused)
        if section == .mail, current?.text == nil { tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification)) }
        if mailbox == .live { Task { await registerCalendar() } }
    }
    func stop() {
        syncFeedback?.cancel(); syncFeedback = nil
        noticeTask?.cancel(); noticeTask = nil
        mailTask?.cancel(); composer?.close(); workspace?.close(); calendarView?.setClock(.stopped)
        notifications?.stop(); editor?.close(); pendingEdits?.close(); pendingEdits = nil
        calendarIdleTask?.cancel()
        idleCalendar = nil
        media.cancel()
        coordinator.setActivity(.paused)
        connectTask?.cancel(); readingTask?.cancel(); searchTask?.cancel()
        refreshTask?.cancel(); calendarTask?.cancel(); folderTask?.cancel()
    }
    func activated() { coordinator.kick() }


    private func buildSidebar() {
        sidebar.frame = layout.sidebar.bounds.insetBy(dx: 2, dy: 2)
        sidebar.autoresizingMask = [.width, .height]
        layout.sidebar.addSubview(sidebar)
        sidebar.onFolder = { [weak self] folder in
            guard let self else { return }
            self.noticeTask?.cancel()
            self.remoteFolder = nil
            self.folder = folder
            self.sidebar.select(folder)
            self.layout.folderLabel.stringValue = folder.title
            self.layout.titleBar.title = "Square Mail - \(folder.title)"
            self.layout.titleBar.needsDisplay = true
            self.setSearchText("")
            Task { await self.loadList() }
        }
        sidebar.onRemoteFolder = { [weak self] folder in
            guard let self else { return }
            self.noticeTask?.cancel()
            self.account = folder.accountId
            for item in self.sidebar.accounts.itemArray where item.representedObject as? String == folder.accountId { self.sidebar.accounts.select(item) }
            self.remoteFolder = folder
            self.layout.folderLabel.stringValue = folder.name
            self.layout.titleBar.title = "Square Mail - " + folder.name
            self.layout.titleBar.needsDisplay = true
            self.setSearchText("")
            Task { await self.loadList() }
        }
        sidebar.accounts.target = self
        sidebar.accounts.action = #selector(changeAccount)
        sidebar.connect.onPress = { [weak self] in self?.connectAccount() }
        sidebar.demo.onPress = { [weak self] in self?.toggleDemo() }
    }

    private func buildToolbar() {
        let accountsButton = ClassicButton("Accounts", icon: .account, style: .toolbar)
        mailButton.onPress = { [weak self] in self?.showMail() }
        calendarButton.onPress = { [weak self] in self?.showCalendar() }
        newButton.onPress = { [weak self] in self?.newMail() }
        replyButton.onPress = { [weak self] in self?.replyMail() }
        replyAllButton.onPress = { [weak self] in self?.replyAllMail() }
        forwardButton.onPress = { [weak self] in self?.forwardMail() }
        archiveButton.onPress = { [weak self] in self?.archiveMail() }
        trashButton.onPress = { [weak self] in self?.trashMail() }
        moveButton.onPress = { [weak self] in self?.moveMail() }
        syncButton.onPress = { [weak self] in self?.syncMail() }
        accountsButton.onPress = { [weak self] in self?.connectAccount() }
        bell.onPress = { [weak self] in self?.noticeService().show() }
        for button in [mailButton, calendarButton, syncButton, accountsButton, bell] {
            layout.toolbar.addItem(button, width: 75, height: 55)
        }
        layout.toolbar.addItem(draftsButton, width: 145)
        layout.toolbar.addItem(splitButton, width: 110)
        layout.filter.addSubview(newButton)
        newButton.frame = NSRect(x: 130, y: 4, width: 95, height: 32)
        textButton.onPress = { [weak self] in self?.setReader(.text) }; htmlButton.onPress = { [weak self] in self?.setReader(.html) }
        splitButton.toolTip = "Switch the reading pane between below and right"
        splitButton.onPress = { [weak self] in guard let self else { return }; setReadingLayout(readingLayout == .below ? .right : .below) }
        readButton.onPress = { [weak self] in self?.toggleRead() }; flagButton.onPress = { [weak self] in self?.toggleFlag() }; pinButton.onPress = { [weak self] in self?.togglePin() }
        draftsButton.onPress = { [weak self] in self?.showMailWorkspace() }
        for (button, width) in [(replyButton, 78.0), (replyAllButton, 90.0), (forwardButton, 92.0), (archiveButton, 90.0), (trashButton, 80.0)] {
            layout.messageActions.addItem(button, width: width)
        }
        for (button, width) in [(moveButton, 90.0), (readButton, 110.0), (flagButton, 100.0), (pinButton, 70.0)] {
            layout.messageActions.addItem(button, width: width, priority: .secondary)
        }
        textButton.setAccessibilityLabel("Plain text")
        htmlButton.setAccessibilityLabel("HTML")
        textButton.toolTip = "Plain text (⌘1). Read the text version without HTML layout."
        htmlButton.toolTip = "HTML (⌘2). Read passive HTML; remote content remains blocked."
        layout.reader.setModeButtons(textButton, html: htmlButton)
        cancelLogin.frame = NSRect(x: 810, y: 6, width: 175, height: 26); cancelLogin.isHidden = true
        cancelLogin.onPress = { [weak self] in self?.connectTask?.cancel(); self?.cancelLogin.isEnabled = false; self?.layout.statusText.stringValue = "Cancelling sign-in…" }
        layout.toolbar.addSubview(cancelLogin)
        textButton.state = .on
        for (index, button) in [more, newer].enumerated() {
            button.frame = NSRect(x: layout.listPane.bounds.width - 76 - CGFloat(index * 72), y: 4, width: 67, height: 22)
            button.autoresizingMask = [.minXMargin]; layout.listPane.addSubview(button)
        }
        more.onPress = { [weak self] in Task { await self?.loadList(page: .older) } }; newer.onPress = { [weak self] in Task { await self?.loadList(page: .newer) } }
        updateMailButtons()
    }

    private var selectedMail: Mail? { messages.indices.contains(table.selectedRow) ? messages[table.selectedRow] : nil }
    private func composeMail(_ kind: ComposeKind) {
        guard mailbox == .live, section == .mail else { return }
        let selected = selectedMail
        guard kind == .new || selected?.id == current?.id else { return }
        let providers = accounts.filter { $0.provider != .local }
        let preferred = providers.first { $0.id == account }?.id ?? providers.first { $0.id == selected?.accountId }?.id ?? providers.first?.id
        let id = kind == .new ? preferred : selected?.accountId
        guard let id else { layout.statusText.stringValue = "Choose an account/message first."; return }
        let composer = mailComposer()
        composer.open(kind, account: id, original: kind == .new ? nil : selected?.id, mode: networkAvailable && networkReady ? .fetch : .cached, accounts: accounts)
    }
    private func openReaderLink(_ url: URL, mail: Mail?) {
        guard PlainRenderer.permits(url) else { return }
        if url.scheme?.lowercased() != "mailto" { if !WindowPresentation.isBackground { NSWorkspace.shared.open(url) }; return }
        guard let seed = MailLinkDraft(url: url) else { layout.statusText.stringValue = "This email link is invalid or exceeds its limit."; return }
        let providers = accounts.filter { $0.provider != .local }
        guard let account = providers.first(where: { $0.id == mail?.accountId }) ?? providers.first else { layout.statusText.stringValue = "Connect an account before composing an email link."; return }
        mailComposer().open(.new, account: account.id, original: nil, mode: .cached, accounts: accounts, seed: seed)
    }
    private func mailComposer() -> MailComposer {
        if let composer { return composer }
        let value = MailComposer(core: core)
        value.onSaved = { [weak self] in self?.workspace?.refresh() }
        value.onQueued = { [weak self] in self?.workspace?.refresh(); self?.coordinator.kick() }
        value.onStatus = { [weak self] value in self?.layout.statusText.stringValue = value }
        composer = value; return value
    }
    @objc private func newMail() { composeMail(.new) }
    @objc private func replyMail() { composeMail(.reply) }
    @objc private func replyAllMail() { composeMail(.replyAll) }
    @objc private func forwardMail() { composeMail(.forward) }
    @objc private func trashMail() { changeMail(["kind": MailActionKind.trash.rawValue]) }
    @objc private func archiveMail() { changeMail(["kind": MailActionKind.archive.rawValue]) }
    @objc private func toggleRead() { guard let value = selectedMail else { return }; changeMail(["kind": MailActionKind.read.rawValue, "unread": !value.unread]) }
    @objc private func toggleFlag() { guard let value = selectedMail else { return }; changeMail(["kind": MailActionKind.flag.rawValue, "flagged": !value.starred]) }
    @objc private func togglePin() {
        guard let value = selectedMail, value.id == current?.id else { return }
        runMailCommand(["command": CoreCommand.pinMail.rawValue, "id": value.id, "pinned": value.pinned != true], message: "Pin updated on this Mac.")
    }
    private func changeMail(_ action: [String: Any]) {
        guard let value = selectedMail, value.id == current?.id, mailbox == .live else { return }
        runMailCommand(["command": CoreCommand.queueMail.rawValue, "operation": UUID().uuidString.lowercased(), "id": value.id, "action": action], message: "Change queued. Drafts / outbox shows sync and consent status.")
    }
    private func runMailCommand(_ command: [String: Any], message: String) {
        guard mailTask == nil, section == .mail else { return }
        let mode = mailbox
        updateMailButtons(.busy)
        mailTask = Task { [weak self] in
            guard let self else { return }
            defer { mailTask = nil; updateMailButtons() }
            do {
                let _: EmptyReply = try await core.request(command, mode: mode)
                await refreshList(); workspace?.refresh(); coordinator.kick()
                layout.statusText.stringValue = message
            } catch { showError(error) }
        }
    }
    @objc private func moveMail() {
        guard mailTask == nil, let value = selectedMail, value.id == current?.id, mailbox == .live else { return }
        let source = remoteFolder?.id
        updateMailButtons(.busy)
        mailTask = Task { [weak self] in
            guard let self else { return }
            defer { mailTask = nil; updateMailButtons() }
            do {
                let folders: [MailFolder] = try await core.request(["command": CoreCommand.moveFolders.rawValue, "account": value.accountId], mode: .live)
                let targets = folders
                guard !targets.isEmpty else { throw MailError(message: "Sync this account's folders first.") }
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 27))
                for folder in targets { picker.addItem(withTitle: folder.name) }
                let alert = NSAlert(); alert.messageText = "Move this message"; alert.informativeText = "Choose a folder in the same account. Gmail keeps unrelated labels."
                alert.accessoryView = picker; alert.addButton(withTitle: "Move"); alert.addButton(withTitle: "Cancel")
                guard WindowPresentation.runAlert(alert) == .alertFirstButtonReturn, targets.indices.contains(picker.indexOfSelectedItem) else { return }
                let target = targets[picker.indexOfSelectedItem]
                let action: [String: Any] = target.system == Folder.trash.rawValue ? ["kind": MailActionKind.trash.rawValue] : ["kind": MailActionKind.move.rawValue, "destination": target.id, "source": source as Any? ?? NSNull()]
                let _: EmptyReply = try await core.request(["command": CoreCommand.queueMail.rawValue, "operation": UUID().uuidString.lowercased(), "id": value.id, "action": action], mode: .live)
                await refreshList(); coordinator.kick(); workspace?.refresh()
                layout.statusText.stringValue = "Move queued. Cached mail remains available offline."
            } catch { showError(error) }
        }
    }
    @objc private func showMailWorkspace() {
        if workspace == nil {
            let value = MailWorkspacePanel(core: core)
            value.onOpen = { [weak self] id in guard let self else { return }; mailComposer().openDraft(id, accounts: accounts) }
            value.onChange = { [weak self] in self?.coordinator.kick(); Task { await self?.refreshList() } }
            value.onConsent = { [weak self] id, access in self?.mailConsent(id, access: access) }
            workspace = value
        }
        workspace?.open(accounts: accounts)
    }
    private func mailConsent(_ id: String, access: MailAccess) {
        guard connectTask == nil else { workspace?.showStatus("Another sign-in is pending. Use Cancel sign-in to stop it."); return }
        workspace?.setAuthorizing(.busy); cancelLogin.isHidden = false
        layout.statusText.stringValue = "Waiting for separate mail consent in your browser."
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { connectTask = nil; cancelLogin.isHidden = true; cancelLogin.isEnabled = true; workspace?.setAuthorizing(.ready) }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.mailConsent.rawValue, "account": id, "access": access.rawValue], mode: .live, queue: .login)
                try await loadAccounts(); startSync(); coordinator.requestRefresh(); workspace?.refresh()
                layout.statusText.stringValue = "Mail consent saved. Queued work will resume."
            } catch { workspace?.showStatus(error.localizedDescription); layout.statusText.stringValue = error.localizedDescription }
        }
    }
    private enum MailButtonPhase { case ready, busy }
    private func updateMailButtons(_ phase: MailButtonPhase = .ready) {
        let selected = selectedMail
        let active = section == .mail && mailbox == .live && phase == .ready && listPhase == .ready && mailTask == nil && selected?.id == current?.id
        let provider = accounts.contains { $0.id == selected?.accountId && $0.provider != .local }
        newButton.isEnabled = section == .mail && mailbox == .live && accounts.contains { $0.provider != .local }
        newButton.isHidden = section != .mail
        layout.searchScope.isHidden = section != .mail
        layout.fuzzy.isHidden = section != .mail
        for button in [replyButton, replyAllButton, forwardButton, trashButton, archiveButton, moveButton, readButton, flagButton, pinButton] { button.isEnabled = active && selected != nil && provider }
        pinButton.isEnabled = active && selected != nil
        readButton.title = selected?.unread == true ? "Mark read" : "Mark unread"
        flagButton.title = selected?.starred == true ? "Unflag" : "Flag / star"
        pinButton.title = selected?.pinned == true ? "Unpin" : "Pin"
        draftsButton.isEnabled = mailbox == .live
        textButton.isEnabled = section == .mail && selected != nil && listPhase == .ready && bodyPhase == .ready
        htmlButton.isEnabled = textButton.isEnabled
        mailButton.state = section == .mail ? .on : .off; calendarButton.state = section == .calendar ? .on : .off
        for button in [mailButton, calendarButton, readButton, flagButton, pinButton] { button.needsDisplay = true }
    }
    private func addMailActions(_ menu: NSMenu) {
        for (title, action) in [("Reply", #selector(replyMail)), ("Reply all", #selector(replyAllMail)), ("Forward", #selector(forwardMail)), ("Move…", #selector(moveMail)), ("Archive", #selector(archiveMail)), ("Move to Trash", #selector(trashMail)), ("Mark read", #selector(toggleRead)), ("Flag / star", #selector(toggleFlag)), ("Pin on this Mac", #selector(togglePin))] { addItem(menu, title, action, "") }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === messageMenu else { return }
        if messages.indices.contains(table.clickedRow) { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        for item in menu.items { item.isEnabled = validateMenuItem(item) }
    }

    private enum MailColumn: String {
        case status, sender, subject, date, account, summary
    }

    private func buildTable() {
        tableHeader = table.headerView
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.gridColor = ClassicTheme.color(0xE5E3DD)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .white
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        messageMenu.delegate = self; addMailActions(messageMenu); table.menu = messageMenu
        table.setAccessibilityLabel("Messages")
        layout.listScroll.documentView = table
        configureColumns()
    }

    private func configureColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        let columns: [(MailColumn, String, CGFloat)] = readingLayout == .right
            ? [(.summary, "", max(300, layout.listScroll.contentSize.width))]
            : [(.status, "", 30), (.sender, "From", 195), (.subject, "Subject", 480),
               (.date, "Received", 145), (.account, "Account", 160)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.title = title
            column.width = width
            column.minWidth = id == .status ? 30 : (id == .summary ? 100 : 80)
            column.headerCell = ClassicHeaderCell(textCell: title)
            table.addTableColumn(column)
        }
        table.rowHeight = readingLayout == .right ? 70 : 28
        table.headerView = readingLayout == .right ? nil : tableHeader
        table.gridStyleMask = readingLayout == .right ? [.solidHorizontalGridLineMask] : [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        layout.listScroll.hasHorizontalScroller = readingLayout == .below
        table.sizeLastColumnToFit()
    }

    private func setReadingLayout(_ value: ReadingLayout, save: LayoutSave = .save) {
        guard value != readingLayout else { return }
        let selected = table.selectedRow
        readingLayout = value
        if save == .save { UserDefaults.standard.set(value.rawValue, forKey: Self.layoutKey) }
        layout.setReadingLayout(value)
        configureColumns()
        table.reloadData()
        if messages.indices.contains(selected) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        }
        updateLayoutButtons()
    }

    private func updateLayoutButtons() {
        splitButton.state = readingLayout == .right ? .on : .off
        splitButton.needsDisplay = true
        for (value, item) in layoutItems { item.state = value == readingLayout ? .on : .off }
    }

    private func loadAccounts() async throws {
        accounts = try await core.request(["command": CoreCommand.accounts.rawValue], mode: mailbox)
        sidebar.accounts.removeAllItems()
        sidebar.accounts.addItem(withTitle: "All accounts")
        for value in accounts {
            sidebar.accounts.addItem(withTitle: value.email)
            sidebar.accounts.lastItem?.representedObject = value.id
        }
        if let account, let index = accounts.firstIndex(where: { $0.id == account }) {
            sidebar.accounts.selectItem(at: index + 1)
        } else { account = nil }
        await loadFolders()
        sidebar.connect.title = "Manage accounts…"
        sidebar.connect.setAccessibilityLabel("Manage accounts")
        sidebar.demo.title = mailbox == .demo ? "My mailbox" : "Demo mailbox"
        sidebar.demo.setAccessibilityLabel(sidebar.demo.title)
        layout.statusMode.stringValue = mailbox == .demo ? "LOCAL DEMO" : "LOCAL CACHE"
    }

    private func loadFolders() async {
        folderTask?.cancel()
        let selected = account
        let mode = mailbox
        guard let selected else { sidebar.showFolders([]); return }
        folderTask = Task {
            do {
                let folders: [MailFolder] = try await core.request(["command": CoreCommand.folders.rawValue, "account": selected], mode: mode)
                guard !Task.isCancelled, selected == account, mode == mailbox else { return }
                sidebar.showFolders(folders)
            } catch is CancellationError {} catch { layout.statusText.stringValue = error.localizedDescription }
        }
        await folderTask?.value
    }

    private var listCommand: [String: Any] {
        ["command": CoreCommand.searchMail.rawValue, "account": (allFolderSearch ? account : remoteFolder?.accountId ?? account) as Any? ?? NSNull(), "folder": (allFolderSearch ? Folder.all : folder).rawValue,
         "folder_id": (allFolderSearch ? nil : remoteFolder?.id) as Any? ?? NSNull(), "query": layout.search.stringValue,
         "mode": searchMode.rawValue, "offset": pageOffset, "limit": Self.pageSize]
    }
    private var allFolderSearch: Bool { searchScope == .allFolders && !layout.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var listTitle: String { allFolderSearch ? "All folders" : folderTitle }
    private func searchIsCurrent(_ command: [String: Any]) -> Bool {
        var expected = listCommand
        expected["offset"] = command["offset"]
        return NSDictionary(dictionary: command).isEqual(NSDictionary(dictionary: expected))
    }
    private var matchCaption: String { searchMatch == .approximate ? "Approximate matches · " : "" }
    @objc private func changeSearchScope() {
        searchScope = MailSearchScope(rawValue: layout.searchScope.indexOfSelectedItem) ?? .folder
        layout.search.placeholderString = searchScope == .allFolders ? "Search all folders (⌘F)" : "Search this folder (⌘F)"
        searchTask?.cancel(); searchTask = Task { await self.loadList() }
    }
    private var folderTitle: String { remoteFolder?.name ?? folder.title }
    private enum ListPage { case start, older, newer }

    private func loadList(page direction: ListPage = .start) async {
        updateClearSearch()
        listRevision += 1
        let revision = listRevision
        listPhase = .loading; updateMailButtons()
        defer { if revision == listRevision { listPhase = .ready; updateMailButtons() } }
        let selected = current?.id
        let offset: Int
        switch direction {
        case .start: offset = 0
        case .older: offset = pageOffset + Self.pageSize
        case .newer: offset = max(0, pageOffset - Self.pageSize)
        }
        bodyRevision += 1
        readingTask?.cancel()
        current = nil
        layout.header.display(nil)
        layout.reader.showNotice("Loading local messages…")
        var command = listCommand
        command["offset"] = offset
        do {
            let result: MailSearchPage = try await core.request(command, mode: mailbox)
            guard !Task.isCancelled, revision == listRevision, searchIsCurrent(command) else { return }
            let page = result.messages; searchMatch = result.kind
            table.deselectAll(nil)
            messages = page
            pageOffset = offset
            table.reloadData()
            updateMailButtons()
            more.isEnabled = page.count == Self.pageSize
            newer.isEnabled = pageOffset > 0
            layout.listCaption.stringValue = "\(listTitle.uppercased())  ·  \(messages.isEmpty ? "0" : "\(offset + 1)-\(offset + messages.count)") SHOWN"
            layout.statusText.stringValue = matchCaption + "\(messages.count) messages  ·  \(messages.filter(\.unread).count) unread  ·  \(mailbox == .demo ? "Demo data" : "Cached on this Mac")"
            if !messages.isEmpty {
                let index = selected.flatMap { id in messages.firstIndex(where: { $0.id == id }) } ?? 0
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
            } else {
                let notice = layout.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (mailbox == .demo ? "No messages match this view." : "No cached messages. Connect an account, then choose Sync.") : "No matches in this search scope.\n\nSearch covers cached sender names, email addresses, subjects, previews and downloaded text. Try All folders or All accounts, or enable Fuzzy."
                layout.reader.showNotice(notice)
            }
        } catch {
            guard !Task.isCancelled, revision == listRevision, searchIsCurrent(command) else { return }
            layout.reader.showNotice(error.localizedDescription)
            layout.statusText.stringValue = "Could not read the local mailbox: " + error.localizedDescription
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view: ClassicRow
        if let reused = tableView.makeView(withIdentifier: Self.rowReuseID, owner: self) as? ClassicRow {
            view = reused
        } else {
            view = ClassicRow()
            view.identifier = Self.rowReuseID
            rowViewsMade += 1
        }
        view.backgroundColor = row % 2 == 0 ? .white : ClassicTheme.row
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard messages.indices.contains(row), let column = tableColumn else { return nil }
        let id = column.identifier
        let mail = messages[row]
        if id.rawValue == MailColumn.summary.rawValue {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MessageSummaryCell) ?? MessageSummaryCell()
            cell.identifier = id
            cell.configure(mail, date: dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(mail.timestamp))))
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell) ?? ClassicTableCell()
        cell.identifier = id
        let weight: ClassicTheme.Weight = mail.unread ? .bold : .regular
        switch MailColumn(rawValue: id.rawValue) {
        case .status: cell.configure("", icon: mail.starred ? .star : (mail.unread ? .mail : nil))
        case .sender: cell.configure(mail.displaySender, weight: weight)
        case .subject: cell.configure((mail.pinned == true ? "Pinned · " : "") + mail.displaySubject, weight: weight, icon: mail.hasAttachments ? .attach : nil)
        case .date: cell.configure(dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(mail.timestamp))))
        case .account: cell.configure(accounts.first(where: { $0.id == mail.accountId })?.email ?? "")
        default: break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateMailButtons()
        guard section == .mail else { return }
        guard messages.indices.contains(table.selectedRow) else {
            current = nil; layout.header.display(nil); layout.reader.showNotice("Select a message to read it.")
            return
        }
        readMessage(messages[table.selectedRow])
    }

    private func readMessage(_ summary: Mail) {
        readingTask?.cancel()
        bodyRevision += 1
        let revision = bodyRevision
        let mode = mailbox
        current = summary
        layout.header.display(summary)
        bodyPhase = .loading; updateMailButtons()
        layout.reader.showNotice("Loading message…")
        readingTask = Task {
            defer { if revision == bodyRevision { bodyPhase = .ready; updateMailButtons() } }
            do {
                var mail: Mail = try await core.request(["command": CoreCommand.message.rawValue, "id": summary.id, "mode": BodyFetch.cached.rawValue], mode: mode)
                guard revision == bodyRevision else { return }
                if mail.text == nil {
                    let arguments = ProcessInfo.processInfo.arguments
                    if !Self.offlineArgs.isDisjoint(with: arguments) {
                        throw MailError(message: "Offline probes require a cached message body")
                    }
                    current = summary
                    layout.header.display(summary)
                    guard networkReady else { layout.reader.showUnavailable("This body has not been downloaded yet."); return }
                    guard networkAvailable else { throw MailError(message: "Offline. Open this message while online to cache its body.") }
                    layout.reader.showLoading("Downloading message body…")
                    mail = try await core.request(["command": CoreCommand.message.rawValue, "id": summary.id, "mode": BodyFetch.fetch.rawValue], mode: mode, queue: .network)
                }
                guard revision == bodyRevision else { return }
                current = mail
                layout.header.display(mail)
                layout.reader.display(mail, mode: readerMode)
            } catch {
                guard revision == bodyRevision else { return }
                current = summary
                layout.header.display(summary)
                layout.reader.showUnavailable("This body is not cached.\n\n\(error.localizedDescription)")
            }
        }
    }

    private func setSearchText(_ value: String) {
        layout.search.stringValue = value
        if let editor = layout.search.currentEditor() as? NSTextView {
            editor.string = value
            editor.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
        }
        updateClearSearch()
    }

    private func clearSearch() {
        searchTask?.cancel(); setSearchText("")
        updateClearSearch()
        if section == .calendar { calendarView?.setQuery("") }
        else { searchTask = Task { await self.loadList() } }
        layout.window?.makeFirstResponder(layout.search)
    }
    private func updateClearSearch() { layout.clearSearch.isHidden = layout.search.stringValue.isEmpty }

    func controlTextDidChange(_ obj: Notification) {
        updateClearSearch()
        searchTask?.cancel()
        if section == .calendar { calendarView?.setQuery(layout.search.stringValue); return }
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            await loadList()
        }
    }

    @objc private func changeAccount() {
        noticeTask?.cancel()
        account = sidebar.accounts.selectedItem?.representedObject as? String
        remoteFolder = nil
        sidebar.select(folder)
        Task { await loadFolders(); await loadList() }
    }

    private func setReader(_ mode: ReaderMode) {
        readerMode = mode
        textButton.state = mode == .text ? .on : .off
        htmlButton.state = mode == .html ? .on : .off
        layout.header.mode = mode
        layout.statusReader.stringValue = mode == .text ? "PLAIN TEXT" : "HTML · REMOTE OFF"
        guard bodyPhase == .ready else { return }
        if let current { layout.reader.display(current, mode: mode) }
    }

    private func moveSelection(_ delta: Int) {
        if section == .calendar { calendarView?.step(delta); return }
        let index = table.selectedRow + delta
        guard messages.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    @objc private func toggleDemo() {
        noticeTask?.cancel()
        setSection(.mail)
        calendarCache = nil
        idleCalendar = nil
        bodyRevision += 1
        mailbox = mailbox == .demo ? .live : .demo
        account = nil
        remoteFolder = nil
        coordinator.setActivity(.paused)
        Task {
            do {
                if mailbox == .demo { let _: EmptyReply = try await core.request(["command": CoreCommand.seedDemo.rawValue], mode: .demo) }
                try await loadAccounts()
                await loadList()
                startSync()
            } catch { showError(error) }
        }
    }

    @objc private func importMail() {
        let panel = NSOpenPanel()
        panel.title = "Import email"
        panel.message = "Choose .eml files to copy into your local mailbox."
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .data]
        guard WindowPresentation.runOpen(panel) == .OK else { return }
        let files = panel.urls
        Task {
            do {
                for file in files {
                    let _: Mail = try await core.request(["command": CoreCommand.importMail.rawValue, "path": file.path], mode: .live)
                }
                mailbox = .live; account = "local"; folder = .inbox
                setSection(.mail)
                sidebar.select(folder)
                layout.folderLabel.stringValue = folder.title
                setSearchText("")
                try await loadAccounts()
                await loadList()
            } catch { showError(error) }
        }
    }

    @objc private func syncMail() {
        guard mailbox == .live else {
            layout.statusText.stringValue = "Demo data is local. Connect an account to sync."
            return
        }
        if !networkReady { startSync() }
        coordinator.requestRefresh(.manual)
        layout.statusText.stringValue = "Refresh requested. Cached mail and calendars remain available."
    }

    private func syncChanged(_ reply: SyncStep) {
        guard mailbox == .live else { return }
        if let error = reply.error {
            let email = accounts.first(where: { $0.id == reply.accountId })?.email ?? "Account"
            layout.statusText.stringValue = email + ": " + error
            return
        }
        workspace?.refresh()
        notifications?.refresh()
        if reply.kind == .catalog { pendingCatalog = true }
        guard refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            if pendingCatalog { pendingCatalog = false; await loadFolders(); await registerCalendar() }
            if section == .calendar { await loadCalendar() }
            else { await refreshList() }
        }
    }

    private func refreshList() async {
        guard section == .mail else { return }
        let revision = listRevision
        let command = listCommand
        do {
            let result: MailSearchPage = try await core.request(command, mode: mailbox)
            let rows = result.messages
            guard !Task.isCancelled, revision == listRevision, section == .mail, searchIsCurrent(command) else { return }
            let changedKind = searchMatch != result.kind
            searchMatch = result.kind
            if rows == messages {
                if changedKind { layout.statusText.stringValue = matchCaption + String(rows.count) + " messages shown" }
                return
            }
            let selected = current?.id
            table.deselectAll(nil)
            messages = rows
            table.reloadData()
            more.isEnabled = rows.count == Self.pageSize
            layout.listCaption.stringValue = "\(listTitle.uppercased())  ·  \(rows.isEmpty ? "0" : "\(pageOffset + 1)-\(pageOffset + rows.count)") SHOWN"
            if let id = selected, let index = rows.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
            } else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            else { current = nil; layout.header.display(nil); layout.reader.showNotice("No cached messages in this view.") }
            updateMailButtons()
            layout.statusText.stringValue = matchCaption + "Cache updated · " + String(rows.count) + " messages shown"
        } catch is CancellationError {} catch { layout.statusText.stringValue = error.localizedDescription }
    }

    @objc private func connectAccount() {
        guard connectTask == nil else { return }
        let dialog = AccountDialog()
        guard let action = dialog.manage(accounts) else { return }
        switch action {
        case .setup: configureClient(dialog)
        case .disconnect(let id): disconnectAccount(id)
        case .add:
            connectTask = Task {
                defer { connectTask = nil; cancelLogin.isHidden = true; cancelLogin.isEnabled = true; sidebar.connect.isEnabled = true }
                do {
                    let gmail: ClientConfig = try await core.request(["command": CoreCommand.clientConfig.rawValue, "provider": Provider.gmail.rawValue], mode: .live, queue: .login)
                    let outlook: ClientConfig = try await core.request(["command": CoreCommand.clientConfig.rawValue, "provider": Provider.outlook.rawValue], mode: .live, queue: .login)
                    guard let input = dialog.run([.gmail: gmail, .outlook: outlook]) else { return }
                    layout.statusText.stringValue = "Waiting for browser consent. Cancel sign-in to stop."
                    cancelLogin.isHidden = false
                    sidebar.connect.isEnabled = false
                    let command: [String: Any] = ["command": CoreCommand.connect.rawValue, "provider": input.provider.rawValue,
                        "client_id": input.clientId, "client_secret": input.clientSecret]
                    let value: Account = try await core.request(command, mode: .live, queue: .login)
                    mailbox = .live; account = value.id; remoteFolder = nil
                    setSection(.mail)
                    try await loadAccounts()
                    await loadList()
                    startSync()
                    coordinator.requestRefresh()
                } catch is CancellationError { layout.statusText.stringValue = "Sign-in cancelled." }
                catch { showError(error) }
            }
        }
    }

    private func configureClient(_ dialog: AccountDialog) {
        guard let input = dialog.setup() else { return }
        var command: [String: Any]
        if input.provider == .gmail {
            let panel = NSOpenPanel()
            panel.title = "Import Google Desktop OAuth JSON"
            panel.allowedContentTypes = [.json]
            guard WindowPresentation.runOpen(panel) == .OK, let url = panel.url else { return }
            command = ["command": CoreCommand.importClient.rawValue, "path": url.path]
        } else { command = ["command": CoreCommand.configure.rawValue, "provider": input.provider.rawValue, "client_id": input.clientId] }
        Task {
            do {
                let _: EmptyReply = try await core.request(command, mode: .live, queue: .login)
                layout.statusText.stringValue = "OAuth setup saved in Keychain. Choose Add / reconnect to sign in."
            } catch { showError(error) }
        }
    }

    private func disconnectAccount(_ id: String) {
        confirmQuit { [weak self] result in
            guard result == .closed else { return }
            self?.chooseDisconnect(id)
        }
    }
    private func chooseDisconnect(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Disconnect this account?"
        alert.informativeText = "Remove saved tokens. Keep downloaded mail and calendar data for offline reading, or remove this account's local cache. Removing the local cache also deletes saved mail/calendar drafts and queued/outbox work for this account. Review Drafts / outbox first. Provider data is unchanged; an in-flight request may already have been accepted."
        alert.addButton(withTitle: "Keep offline cache")
        alert.addButton(withTitle: "Remove local cache")
        alert.addButton(withTitle: "Cancel")
        let reply = WindowPresentation.runAlert(alert)
        guard reply == .alertFirstButtonReturn || reply == .alertSecondButtonReturn else { return }
        finishDisconnect(id, reply: reply)
    }

    private func finishDisconnect(_ id: String, reply: NSApplication.ModalResponse) {
        mailTask?.cancel(); workspace?.close()
        noticeTask?.cancel()
        media.cancel()
        editor?.close(); pendingEdits?.close()
        calendarCache = nil
        setSection(.mail)
        idleCalendar = nil
        coordinator.setActivity(.paused)
        readingTask?.cancel()
        Task {
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.disconnect.rawValue, "account": id,
                    "mode": reply == .alertFirstButtonReturn ? AccountDisconnect.keepCache.rawValue : AccountDisconnect.removeCache.rawValue], mode: .live, queue: .login)
                try await loadAccounts()
                await loadList()
                startSync()
            } catch { showError(error) }
        }
    }

    private func showError(_ error: Error) {
        layout.statusText.stringValue = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "Square Mail"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        WindowPresentation.runAlert(alert)
    }

    private func buildMenus() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Square Mail", action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Square Mail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Square Mail", action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: "File")
        addItem(file, "New mail…", #selector(newMail), "n")
        addItem(file, "Mail drafts / outbox…", #selector(showMailWorkspace), "")
        addItem(file, "Import .eml…", #selector(importMail), "o")
        addItem(file, "Connect account…", #selector(connectAccount), ",")
        addItem(file, "Switch demo / my mailbox", #selector(toggleDemo), "d")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select all", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        addItem(edit, "Search this folder", #selector(focusSearch), "f")
        let view = NSMenu(title: "View")
        addItem(view, "Plain text", #selector(showText), "1")
        addItem(view, "HTML, remote content blocked", #selector(showHTML), "2")
        addItem(view, "Calendar", #selector(showCalendar), "3")
        addItem(view, "Mail", #selector(showMail), "4")
        view.addItem(.separator())
        for (value, title, action) in [(ReadingLayout.below, "Reading pane below", #selector(paneBelow)),
                                        (.right, "Reading pane on right", #selector(paneRight))] {
            let item = view.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            layoutItems[value] = item
        }
        let appearance = NSMenu(title: "Appearance")
        addItem(appearance, "Classic", #selector(classicAppearance), "")
        addItem(appearance, "Pink", #selector(pinkAppearance), "")
        appearance.addItem(.separator())
        appearance.addItem(withTitle: "Applies after restarting Square Mail", action: nil, keyEquivalent: "")
        view.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "").submenu = appearance
        let tools = NSMenu(title: "Tools")
        addItem(tools, "Refresh mail and calendars", #selector(syncMail), "r")
        addItem(tools, "Notifications…", #selector(showNotices), "")
        addItem(file, "New calendar event…", #selector(newCalendarEvent), "")
        addItem(file, "Calendar drafts / pending…", #selector(showCalendarChanges), "")
        let messageActions = NSMenu(title: "Message"); addMailActions(messageActions)
        let help = NSMenu(title: "Help")
        addItem(help, "App updates…", #selector(openAppUpdates), "")
        help.items.last?.toolTip = "Open f1nb0 Apps to check, download and install updates."
        addItem(help, "About this preview", #selector(showAbout), "")
        for menu in [file, edit, view, messageActions, tools, help] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        for item in app.items where item.action == #selector(showAbout) { item.target = self }
        NSApp.mainMenu = main
        var x: CGFloat = 0
        for menu in [file, edit, view, messageActions, tools, help] {
            let button = ClassicButton(menu.title, style: .menu)
            let width = max(48, CGFloat(menu.title.count * 7 + 18))
            button.frame = NSRect(x: x, y: 0, width: width, height: 24)
            button.onPress = { [weak button] in
                guard let button else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
            layout.menus.addSubview(button)
            x += width
        }
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    var needsQuitConfirm: Bool { editor?.requiresClosePrompt == true || composer?.needsClosePrompt == true }
    func confirmQuit(_ reply: @escaping (CalendarEditor.CloseOutcome) -> Void) {
        let finish: () -> Void = { [weak self] in
            guard let editor = self?.editor else { reply(.closed); return }
            editor.requestClose(reply)
        }
        guard let composer else { finish(); return }
        composer.requestClose { result in if result == .closed { finish() } else { reply(.cancelled) } }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newMail): return mailbox == .live && section == .mail && accounts.contains { $0.provider != .local }
        case #selector(showMailWorkspace): return mailbox == .live
        case #selector(replyMail), #selector(replyAllMail), #selector(forwardMail), #selector(trashMail), #selector(archiveMail), #selector(moveMail), #selector(toggleRead), #selector(toggleFlag), #selector(togglePin):
            if item.action == #selector(toggleRead) { item.title = selectedMail?.unread == true ? "Mark as read" : "Mark as unread" }
            if item.action == #selector(toggleFlag) { item.title = selectedMail?.starred == true ? "Unflag / unstar" : "Flag / star" }
            if item.action == #selector(togglePin) { item.title = selectedMail?.pinned == true ? "Unpin on this Mac" : "Pin on this Mac" }
            return mailbox == .live && section == .mail && listPhase == .ready && selectedMail != nil && selectedMail?.id == current?.id && mailTask == nil

        case #selector(classicAppearance): item.state = pendingAppearance == .classic ? .on : .off
        case #selector(pinkAppearance): item.state = pendingAppearance == .pink ? .on : .off
        case #selector(showText): item.state = section == .mail && readerMode == .text ? .on : .off
        case #selector(showHTML): item.state = section == .mail && readerMode == .html ? .on : .off
        case #selector(showCalendar): item.state = section == .calendar ? .on : .off
        case #selector(showMail): item.state = section == .mail ? .on : .off
        case #selector(paneBelow), #selector(paneRight): return section == .mail
        case #selector(importMail): return section == .mail
        case #selector(connectAccount): return connectTask == nil
        case #selector(newCalendarEvent), #selector(showCalendarChanges): return mailbox == .live && accounts.contains { $0.provider != .local }
        default: break
        }
        return true
    }
    @objc private func showNotices() { noticeService().show() }
    @objc private func newCalendarEvent() { setSection(.calendar); openEditor(nil, date: calendarState.date) }
    @objc private func showCalendarChanges() { setSection(.calendar); showPending() }

    @objc private func focusSearch() { layout.window?.makeFirstResponder(layout.search) }
    @objc private func classicAppearance() { chooseAppearance(.classic) }
    @objc private func pinkAppearance() { chooseAppearance(.pink) }
    private func chooseAppearance(_ appearance: ClassicTheme.Appearance) {
        pendingAppearance = appearance
        if !WindowPresentation.isBackground { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
        layout.statusText.stringValue = appearance == ClassicTheme.appearance ? "Appearance is already active." : "Appearance saved. Restart Square Mail to apply."
    }
    @objc private func showText() { setSection(.mail); setReader(.text) }
    @objc private func showHTML() { setSection(.mail); setReader(.html) }
    @objc private func showCalendar() { setSection(.calendar) }
    @objc private func showMail() { setSection(.mail) }
    @objc private func toggleCalendar() { setSection(section == .mail ? .calendar : .mail) }
    @objc private func paneBelow() { setReadingLayout(.below) }
    @objc private func paneRight() { setReadingLayout(.right) }

    private enum MailReload { case refresh, skip }
    private func setSection(_ next: Section, reload: MailReload = .refresh) {
        guard next != section else { return }
        searchTask?.cancel()
        section = next
        updateMailButtons()
        calendarView?.setClock(.stopped)
        splitButton.isEnabled = next == .mail
        if next == .calendar {
            calendarIdleTask?.cancel()
            calendarIdleTask = nil
            let cached = calendarMode == mailbox ? idleCalendar : nil
            calendarMode = mailbox
            idleCalendar = nil
            listRevision += 1
            bodyRevision += 1
            readingTask?.cancel()
            mailSearch = layout.search.stringValue
            layout.split.isHidden = true
            sidebar.isHidden = true
            layout.reader.pause()
            let view = cached?.0 ?? CalendarView(state: calendarState, mode: mailbox)
            let side = cached?.1 ?? CalendarSidebar(state: calendarState, mode: mailbox)
            view.frame = layout.split.frame
            view.autoresizingMask = [.width, .height]
            side.frame = layout.sidebar.bounds.insetBy(dx: 2, dy: 2)
            side.autoresizingMask = [.width, .height]
            view.onNew = { [weak self] date in self?.openEditor(nil, date: date) }
            view.onEdit = { [weak self] key in self?.openEditor(key, date: Date()) }
            view.onClockTick = { [weak side] in side?.redrawToday() }
            view.onPending = { [weak self] in self?.showPending() }
            side.onDate = { [weak view] date in view?.selectDate(date) }
            side.onFeeds = { [weak view] feeds in view?.setFeeds(feeds) }
            side.onMail = { [weak self] in self?.setSection(.mail) }
            side.onHiddenSources = { [weak view] hidden in view?.setHidden(hidden) }
            view.onDateChanged = { [weak self, weak side] date in
                side?.showDate(date)
                self?.scheduleCalendar()
            }
            if cached == nil, mailbox == .live, let cache = calendarCache {
                cache.restore(view)
                side.showSources(cache.sources, accounts: accounts, hidden: view.state.hiddenSources)
            }
            layout.addSubview(view)
            layout.sidebar.addSubview(side)
            calendarView = view
            view.setClock(.running)
            calendarSidebar = side
            layout.folderLabel.stringValue = "Calendar"
            layout.titleBar.title = "Square Mail - Calendar"
            setSearchText(calendarState.query)
            layout.search.placeholderString = mailbox == .demo ? "Search sample events (⌘F)" : "Search cached events (⌘F)"
            layout.statusText.stringValue = mailbox == .demo ? "Sample calendars · not connected" : (accounts.contains(where: { $0.connected == true }) ? "Cached calendars · updates while online" : "Offline calendars · reconnect an account to update")
            layout.statusMode.stringValue = mailbox == .demo ? "LOCAL DEMO" : "LOCAL CACHE"
            scheduleCalendar()
            layout.statusReader.stringValue = "CALENDAR"
        } else {
            calendarTask?.cancel()
            calendarRevision += 1
            if let view = calendarView { calendarState = view.state }
            if let view = calendarView, let side = calendarSidebar { idleCalendar = (view, side) }
            calendarView?.removeFromSuperview(); calendarView = nil
            calendarSidebar?.removeFromSuperview(); calendarSidebar = nil
            calendarIdleTask?.cancel()
            calendarIdleTask = Task { [weak self] in
                do { try await Task.sleep(for: Self.calendarIdleDelay) } catch { return }
                self?.idleCalendar = nil
                self?.calendarIdleTask = nil
            }
            layout.split.isHidden = false
            sidebar.isHidden = false
            layout.folderLabel.stringValue = folderTitle
            layout.titleBar.title = "Square Mail - \(folderTitle)"
            setSearchText(mailSearch)
            layout.search.placeholderString = searchScope == .allFolders ? "Search all folders (⌘F)" : "Search this folder (⌘F)"
            layout.statusText.stringValue = "\(messages.count) messages shown · Cached on this Mac"
            layout.statusMode.stringValue = mailbox == .demo ? "LOCAL DEMO" : "LOCAL CACHE"
            setReader(readerMode)
            if reload == .refresh {
                let revision = listRevision
                Task {
                    guard section == .mail, revision == listRevision else { return }
                    await loadList()
                }
            }
        }
        updateClearSearch()
        layout.titleBar.needsDisplay = true
        layout.search.setAccessibilityLabel(next == .calendar ? (mailbox == .demo ? "Search sample events" : "Search cached events") : "Search this folder")
        calendarButton.setAccessibilityLabel(calendarButton.title)
        calendarButton.needsDisplay = true
    }

    private func noticeService() -> NotificationService {
        if let notifications { return notifications }
        let service = NotificationService(core: core)
        service.onCount = { [weak self] count in
            self?.bell.title = count == 0 ? "Alerts" : "Alerts (\(count))"
            self?.bell.setAccessibilityLabel("Notifications, \(count) unread")
            self?.bell.needsDisplay = true
        }
        service.onOpen = { [weak self] notice in self?.openNotice(notice) }
        service.onStatus = { [weak self] status in self?.layout.statusText.stringValue = status }
        notifications = service
        return service
    }
    private func eventEditor() -> CalendarEditor {
        if let editor { return editor }
        let service = CalendarEditor(core: core)
        service.onStatus = { [weak self] status in self?.layout.statusText.stringValue = status }
        service.onQueued = { [weak self] in self?.coordinator.requestRefresh(); self?.notifications?.refresh() }
        editor = service
        return service
    }
    private func openEditor(_ key: EventKey?, date: Date) {
        guard mailbox == .live else { return }
        eventEditor().open(key, date: date, sources: calendarCache?.sources ?? [], accounts: accounts)
    }
    private func showPending() {
        if pendingEdits == nil {
            let view = PendingEdits(core: core)
            view.onOpen = { [weak self] key in self?.openEditor(key, date: Date()) }
            view.onDraft = { [weak self] draft in
                guard let self else { return }
                eventEditor().openDraft(draft, sources: calendarCache?.sources ?? [], accounts: accounts)
            }
            pendingEdits = view
        }
        pendingEdits?.open()
    }
    private func openNotice(_ notice: AppNotice) {
        noticeTask?.cancel()
        noticeTask = Task {
            do {
                if mailbox == .demo {
                    setSection(.mail, reload: .skip)
                    mailbox = .live; calendarCache = nil; idleCalendar = nil
                }
                try await loadAccounts()
                guard !Task.isCancelled, accounts.contains(where: { $0.id == notice.account }) else { return }
                if let calendar = notice.calendar, !calendar.isEmpty {
                    if notice.target.isEmpty { showPending(); return }
                    setSection(.calendar)
                    await loadCalendar()
                    guard !Task.isCancelled, section == .calendar else { return }
                    openEditor(EventKey(account: notice.account, calendar: calendar, id: notice.target), date: Date(timeIntervalSince1970: TimeInterval(notice.occurred)))
                    return
                }
                setSection(.mail, reload: .skip)
                account = notice.account; remoteFolder = nil; folder = .all
                setSearchText("")
                sidebar.select(.all)
                layout.folderLabel.stringValue = folder.title
                try await loadAccounts()
                await loadList()
                let revision = bodyRevision
                let mail: Mail = try await core.request(["command": CoreCommand.message.rawValue, "id": notice.target, "mode": BodyFetch.cached.rawValue], mode: .live)
                guard !Task.isCancelled, section == .mail, revision == bodyRevision, account == notice.account else { return }
                table.deselectAll(nil)
                readMessage(mail)
            } catch is CancellationError {} catch { layout.statusText.stringValue = error.localizedDescription }
        }
    }

    private func scheduleCalendar() {
        calendarTask?.cancel()
        calendarRevision += 1
        let revision = calendarRevision
        calendarTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let self, revision == self.calendarRevision else { return }
            await self.loadCalendar()
        }
    }

    private func registerCalendar() async {
        guard mailbox == .live else { return }
        let range = calendarView?.range ?? (Date(), Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var month = calendar.dateInterval(of: .month, for: range.0)!.start
        let end = calendar.dateInterval(of: .month, for: range.1)!.end
        var months: Set<Int64> = []
        while month < end {
            months.insert(Int64(month.timeIntervalSince1970))
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        let current = calendar.dateInterval(of: .month, for: Date())!.start
        months.insert(Int64(current.timeIntervalSince1970))
        months.insert(Int64(calendar.date(byAdding: .month, value: 1, to: current)!.timeIntervalSince1970))
        do {
            let _: EmptyReply = try await core.request(["command": CoreCommand.calendarWindows.rawValue, "months": months.sorted()], mode: .live)
        } catch is CancellationError {} catch { layout.statusText.stringValue = error.localizedDescription }
    }

    private func loadCalendar() async {
        guard mailbox == .live, section == .calendar, let view = calendarView else { return }
        let revision = calendarRevision
        let range = view.range
        do {
            let sources: [CalendarSource] = try await core.request(["command": CoreCommand.calendars.rawValue], mode: .live)
            let events: [CalendarEvent] = try await core.request(["command": CoreCommand.events.rawValue, "start": Int64(range.0.timeIntervalSince1970),
                "end": Int64(range.1.timeIntervalSince1970), "offset": 0, "limit": 2000], mode: .live)
            guard !Task.isCancelled, revision == calendarRevision, calendarView === view else { return }
            if calendarCache?.sources != sources || calendarCache?.events != events {
                view.setData(sources: sources, events: events)
                calendarCache = CalendarCache(sources: sources, events: events, restore: view.snapshot())
            }
            calendarSidebar?.showSources(sources, accounts: accounts, hidden: view.state.hiddenSources)
            await registerCalendar()
        } catch is CancellationError {} catch { layout.statusText.stringValue = error.localizedDescription }
    }

    private func checkHeaderText() throws {
        let json = #"{"id":"entities","account_id":"fixture","remote_id":"entities","sender":"Ada &amp; Co.","sender_address":"literal&amp;box@example.test","recipient":"fin@example.test","subject":"Offers &amp; Updates &#39;Today&#39;","preview":"You&#39;re getting noticed&nbsp;&nbsp;today","timestamp":0,"unread":false,"starred":false,"has_attachments":false}"#
        let sample = try JSONDecoder().decode(Mail.self, from: Data(json.utf8))
        let cell = MessageSummaryCell()
        cell.configure(sample, date: "Today")
        let labels = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        guard labels.contains("Ada & Co."), labels.contains("Offers & Updates 'Today'"), labels.contains("You're getting noticed today"),
              sample.subject == "Offers &amp; Updates &#39;Today&#39;", sample.senderAddress == "literal&amp;box@example.test", sample.displayFrom == "Ada & Co. <literal&amp;box@example.test>" else { throw MailError(message: "Header entity rendering changed source data or missed a label") }
        layout.header.display(sample)
        defer { layout.header.display(current) }
        try WindowPresentation.snapshot(layout, name: "header-entities")
    }

    func checkMailActions() async throws {
        guard WindowPresentation.isBackground, accounts.count == 1, accounts.first?.email == "fin@example.test", accounts.first?.connected == false, let original = selectedMail?.id else { throw MailError(message: "Use the disconnected mail-actions fixture") }
        try await SyncCoordinator.verifyFlow()
        await finishSelection(); try await layout.reader.verifySpacing()
        try checkHeaderText()
        try verifyActionPlacement()
        guard let summary = selectedMail else { throw MailError(message: "Reader action fixture lost selection") }
        readMessage(summary); layout.reader.onCancelLoad?()
        await readingTask?.value
        guard bodyPhase == .ready, current?.id == summary.id else { throw MailError(message: "Cancelled body load changed selection or stayed busy") }
        layout.reader.onRetryLoad?(); await finishSelection()
        guard current?.text != nil else { throw MailError(message: "Reader Retry did not restore the cached body") }
        readButton.performClick(nil); await mailTask?.value
        guard selectedMail?.unread == false, readButton.title == "Mark unread" else { throw MailError(message: "Read action did not update the native list") }
        flagButton.performClick(nil); await mailTask?.value
        guard selectedMail?.starred == true, flagButton.title == "Unflag" else { throw MailError(message: "Flag action did not update the native list") }
        pinButton.performClick(nil); await mailTask?.value
        guard selectedMail?.pinned == true, pinButton.title == "Unpin" else { throw MailError(message: "Local pin did not update the native list") }
        menuNeedsUpdate(messageMenu)
        guard let archive = messageMenu.items.first(where: { $0.action == #selector(archiveMail) }), validateMenuItem(archive), NSApp.sendAction(#selector(archiveMail), to: archive.target, from: archive) else { throw MailError(message: "Context menu did not dispatch Archive") }
        await mailTask?.value
        guard messages.isEmpty else { throw MailError(message: "Archive did not remove the Inbox row") }
        folder = .archive; await loadList(); trashButton.performClick(nil); await mailTask?.value
        folder = .trash; await loadList()
        guard selectedMail?.id == original else { throw MailError(message: "Delete did not move the message to Trash") }
        trashButton.performClick(nil); await mailTask?.value
        guard selectedMail?.id == original else { throw MailError(message: "Delete from Trash removed the message permanently") }
        let batch: MailWorkspace = try await core.request(["command": CoreCommand.mailWorkspace.rawValue], mode: .live)
        guard batch.work.count == 3, batch.work.allSatisfy({ $0.kind == .action && $0.state == .pending }) else { throw MailError(message: "Offline read/flag/placement changes were not coalesced") }
        let prompts = ScriptedEditorPrompts(); let composer = MailComposer(core: core, prompts: prompts)
        try await composer.verifyControls(prompts, accounts: accounts, original: original)
        let workspace = MailWorkspacePanel(core: core); try await workspace.verifyControls(accounts: accounts)
        calendarButton.performClick(nil)
        guard section == .calendar, mailButton.frame.minX < calendarButton.frame.minX else { throw MailError(message: "Left navigation did not enter Calendar") }
        let offset = Calendar.current.component(.weekday, from: Date()) == 1 ? -1 : 1
        calendarView?.selectDate(Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
        try calendarView?.verifyClock()
        coordinator.onStatus?(.checking)
        let progressDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while layout.syncProgress.isHidden && ContinuousClock.now < progressDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !syncButton.isEnabled, syncButton.title == "Checking…", !layout.syncProgress.isHidden, layout.syncProgress.state == .indeterminate else { throw MailError(message: "Sync activity did not disable duplicate work: title=\(syncButton.title), enabled=\(syncButton.isEnabled), hidden=\(layout.syncProgress.isHidden)") }
        coordinator.onStatus?(.syncing)
        guard !layout.syncProgress.isHidden, syncButton.title == "Syncing…" else { throw MailError(message: "Sync progress disappeared between pages") }
        mailButton.performClick(nil)
        guard !syncButton.isEnabled else { throw MailError(message: "Navigation re-enabled an active sync button") }
        coordinator.onStatus?(.offline)
        guard syncButton.isEnabled, syncButton.title == "Refresh", layout.syncProgress.isHidden, !syncButton.isHighlighted, layout.syncProgress.state == .idle else { throw MailError(message: "Offline sync retained its busy state") }
        let appearance = pendingAppearance
        chooseAppearance(appearance == .classic ? .pink : .classic)
        guard pendingAppearance != appearance, ClassicTheme.appearance == appearance else { throw MailError(message: "Appearance choice did not remain pending until restart") }
        chooseAppearance(appearance)
        await loadList(); await finishSelection()
        layout.folderLabel.stringValue = folder.title; sidebar.select(folder)
        try WindowPresentation.snapshot(layout, name: "mail-actions")
        guard section == .mail, mailButton.state == .on, calendarButton.state == .off, !NSApp.isActive, layout.window?.isVisible != true else { throw MailError(message: "Mail navigation or background isolation failed") }
        print("MAIL ACTIONS verified native toolbar/context dispatch, read/flag/pin, offline archive/trash, compose autosave/close, reply-all/forward, outbox cancellation and spacing preservation. No provider writes, sends or consent requests.")
    }

    func checkControls() async throws {
        guard WindowPresentation.isBackground, accounts.count == 1, accounts.first?.email == "fin@example.test", accounts.first?.connected == false else {
            throw MailError(message: "Use the disconnected actions fixture and --background-ui")
        }
        let sources: [CalendarSource] = try await core.request(["command": CoreCommand.calendars.rawValue], mode: .live)
        let prompts = ScriptedEditorPrompts()
        let editor = CalendarEditor(core: core, prompts: prompts)
        editor.open(EventKey(account: "fixture", calendar: "primary", id: "event"), date: Date(), sources: sources, accounts: accounts)
        try await editor.verifyControls(prompts)
        let pending = PendingEdits(core: core)
        try await pending.verifyControls()
        let notices: NoticeBatch = try await core.request(["command": CoreCommand.notices.rawValue, "delivery": NoticeDelivery.quiet.rawValue], mode: .live)
        try await noticeService().verifyControls(notices, accounts: accounts)
        guard !NSApp.isActive, layout.window?.isVisible != true else { throw MailError(message: "Background control probe activated a host window") }
        guard let main = NSApp.mainMenu, let view = main.items.first(where: { $0.title == "View" })?.submenu else { throw MailError(message: "View menu is missing") }
        guard let help = main.items.first(where: { $0.title == "Help" })?.submenu,
              let updates = help.items.first(where: { $0.action == #selector(openAppUpdates) }),
              updates.target === self, validateMenuItem(updates), updates.state == .off,
              updates.toolTip?.isEmpty == false else { throw MailError(message: "Update-manager menu entry is missing or stuck") }
        func item(_ action: Selector) throws -> NSMenuItem {
            guard let value = view.items.first(where: { $0.action == action }) else { throw MailError(message: "View action is missing") }
            return value
        }
        func dispatch(_ action: Selector) throws {
            let value = try item(action)
            guard validateMenuItem(value), NSApp.sendAction(action, to: value.target, from: value) else { throw MailError(message: "View menu did not dispatch its action") }
        }
        for _ in 0..<3 {
            calendarButton.performClick(nil)
            guard section == .calendar, layout.split.isHidden, !calendarButton.isHighlighted else { throw MailError(message: "Calendar toolbar button retained a pressed or stale state") }
            let pane = try item(#selector(paneRight))
            guard !validateMenuItem(pane) else { throw MailError(message: "Reading-pane menu is enabled in Calendar") }
            try dispatch(#selector(showMail)); try dispatch(#selector(showText))
            let text = try item(#selector(showText)); _ = validateMenuItem(text)
            guard section == .mail, readerMode == .text, text.state == .on, textButton.state == .on, htmlButton.state == .off else { throw MailError(message: "Plain-text menu and toolbar states diverged") }
            try dispatch(#selector(showHTML))
            let html = try item(#selector(showHTML)); _ = validateMenuItem(html)
            guard readerMode == .html, html.state == .on, htmlButton.state == .on, textButton.state == .off else { throw MailError(message: "HTML menu and toolbar states diverged") }
        }
        showText()
        importMail()
        guard WindowPresentation.lastDialog?.title == "Import email" else { throw MailError(message: "Import did not present its file picker") }
        connectAccount()
        guard WindowPresentation.lastDialog?.title == "Mail and calendar accounts", connectTask == nil, sidebar.connect.isEnabled else { throw MailError(message: "Cancelled account prompt left controls blocked") }
        showAbout()
        guard WindowPresentation.lastDialog?.title == "Square Mail 0.1" else { throw MailError(message: "About action did not present its dialog") }
        print("CONTROLS verified hidden native buttons, view menus, import/account/about dialogs, unsaved-edit prompts, local draft restore and save-error recovery. No foreground windows or provider writes.")
    }

    func checkActions(_ mode: CalendarProbe = .validate) async throws {
        guard accounts.count == 1, accounts.first?.email == "fin@example.test", accounts.first?.connected == false else { throw MailError(message: "Use the disconnected actions fixture") }
        let batch: NoticeBatch = try await core.request(["command": CoreCommand.notices.rawValue, "delivery": NoticeDelivery.quiet.rawValue], mode: .live)
        guard batch.items.count == 50, batch.banners.isEmpty, batch.planned.isEmpty else { throw MailError(message: "Notification history or desktop opt-in bounds failed") }
        let _: EmptyReply = try await core.request(["command": CoreCommand.noticeAction.rawValue, "action": NoticeAction.read.rawValue, "id": batch.items.first!.id], mode: .live)
        let updated: NoticeBatch = try await core.request(["command": CoreCommand.notices.rawValue, "delivery": NoticeDelivery.quiet.rawValue], mode: .live)
        guard updated.items.filter(\.unread).count == 49 else { throw MailError(message: "Notification read state was not persisted") }
        let sources: [CalendarSource] = try await core.request(["command": CoreCommand.calendars.rawValue], mode: .live)
        let cached: [Mail] = try await core.request(["command": CoreCommand.list.rawValue, "account": "fixture", "folder": Folder.all.rawValue, "query": "", "offset": 0, "limit": 1], mode: .live)
        guard let mail = cached.first else { throw MailError(message: "Actions fixture needs its cached notification message") }
        setSection(.calendar)
        openNotice(AppNotice(id: "fixture-mail-notice", account: "fixture", kind: .mail, target: mail.id, calendar: nil, title: "Mail", detail: "", occurred: mail.timestamp, unread: true))
        await noticeTask?.value
        await finishSelection()
        guard current?.id == mail.id, current?.text?.contains("Notification body") == true else { throw MailError(message: "Notification click did not use the cached mail reader") }
        let key = EventKey(account: "fixture", calendar: "primary", id: "event")
        let begin = ProcessInfo.processInfo.systemUptime
        let editor = eventEditor()
        editor.open(key, date: Date(), sources: sources, accounts: accounts)
        try await editor.verify()
        layout.window?.displayIfNeeded()
        let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        if mode == .preview { noticeService().preview(updated, accounts: accounts) }
        else {
            editor.close()
            let _: EmptyReply = try await core.request(["command": CoreCommand.noticeAction.rawValue, "action": NoticeAction.clear.rawValue, "id": NSNull()], mode: .live)
            let empty: NoticeBatch = try await core.request(["command": CoreCommand.notices.rawValue, "delivery": NoticeDelivery.quiet.rawValue], mode: .live)
            guard empty.items.isEmpty else { throw MailError(message: "Notification clear failed") }
        }
        print("ACTIONS verified cached native editor, metadata retention and bounded notification read/clear state. Cached editor \(String(format: "%.2f", elapsed)) ms. No consent, calendar writes or OS notifications.")
    }

    func checkAccounts() async throws {
        guard mailbox == .live, accounts.count == 3, accounts.allSatisfy({ $0.email.hasSuffix("@example.test") && $0.connected == false }) else {
            throw MailError(message: "Use the disconnected synthetic account fixture")
        }
        for value in accounts {
            account = value.id
            remoteFolder = nil
            setSearchText("")
            folder = .inbox
            await loadFolders()
            await loadList()
            await finishSelection()
            guard messages.count == Self.pageSize, messages.allSatisfy({ $0.accountId == value.id }), current?.text?.contains(value.id) == true else {
                throw MailError(message: "Account fixture mismatch: \(value.id), rows \(messages.count), current \(current?.accountId ?? "none"), selected \(table.selectedRow), body \(current?.text?.contains(value.id) == true), command \(listCommand), mode \(mailbox), \(layout.statusText.stringValue)")
            }
            try layout.reader.verifyText(current!.text!)
            let folders: [MailFolder] = try await core.request(["command": CoreCommand.folders.rawValue, "account": value.id], mode: .live)
            remoteFolder = folders.first(where: { $0.parentId != nil })
            guard remoteFolder != nil else { throw MailError(message: "Nested folders were lost") }
            await loadList()
            guard messages.count == Self.pageSize else {
                throw MailError(message: "Nested folder paging failed: \(value.id), rows \(messages.count), command \(listCommand), mode \(mailbox), \(layout.statusText.stringValue)")
            }
            setSearchText(value.id + " project")
            await loadList()
            guard !messages.isEmpty, messages.allSatisfy({ $0.accountId == value.id }) else { throw MailError(message: "Scoped search lost account isolation") }
            setSearchText("ada@example.test"); await loadList()
            guard messages.count == Self.pageSize, searchMatch == .literal, messages.allSatisfy({ $0.accountId == value.id && $0.text == nil }) else { throw MailError(message: "Address search lost bounded headers or account scope") }
            setSearchText("ada@exmaple.test"); await loadList()
            guard searchMatch == .approximate, messages.count == Self.pageSize else { throw MailError(message: "Fuzzy email search lost approximate feedback") }
            layout.fuzzy.performClick(nil); await searchTask?.value
            guard searchMode == .literal, messages.isEmpty else { throw MailError(message: "Literal toggle kept fuzzy results") }
            layout.fuzzy.performClick(nil); await searchTask?.value
            layout.searchScope.selectItem(at: MailSearchScope.allFolders.rawValue)
            changeSearchScope(); await searchTask?.value
            guard listCommand["folder"] as? String == Folder.all.rawValue, listCommand["folder_id"] is NSNull, messages.allSatisfy({ $0.accountId == value.id }) else { throw MailError(message: "All folders changed the account scope") }
            layout.clearSearch.performClick(nil); await searchTask?.value
            guard layout.search.stringValue.isEmpty, layout.search.currentEditor()?.string.isEmpty != false, searchScope == .allFolders, searchMode == .smart, messages.count == Self.pageSize else { throw MailError(message: "Clear search changed filters or did not restore mail") }
            layout.searchScope.selectItem(at: MailSearchScope.folder.rawValue)
            changeSearchScope(); await searchTask?.value

        }
        account = nil; remoteFolder = nil; setSearchText("")
        await loadList()
        guard Set(messages.map(\.accountId)).count == 3 else { throw MailError(message: "Unified inbox omitted an account") }
        setSearchText("ada@exmaple.test"); await loadList()
        guard searchMatch == .approximate, Set(messages.map(\.accountId)).count == 3 else { throw MailError(message: "Unified fuzzy search lost an account") }
        await finishSelection()
        try WindowPresentation.snapshot(layout, name: "fuzzy-search")
        layout.clearSearch.performClick(nil); await searchTask?.value

        setSection(.calendar)
        calendarTask?.cancel()
        await loadCalendar()
        let sources: [CalendarSource] = try await core.request(["command": CoreCommand.calendars.rawValue], mode: .live)
        guard sources.count == 12 else { throw MailError(message: "Calendar sources lost an account") }
        let range = calendarView!.range
        let events: [CalendarEvent] = try await core.request(["command": CoreCommand.events.rawValue,
            "start": Int64(range.0.timeIntervalSince1970), "end": Int64(range.1.timeIntervalSince1970), "offset": 0, "limit": 2000], mode: .live)
        guard events.count == 2000 else { throw MailError(message: "Bounded calendar events were not loaded") }
        for _ in 0..<5 {
            let retired = NSHashTable<AnyObject>.weakObjects()
            if let view = calendarView { retired.add(view) }
            if let side = calendarSidebar { retired.add(side) }
            setSection(.mail)
            try await Task.sleep(for: .milliseconds(30))
            setSection(.calendar)
            guard retired.allObjects.contains(where: { $0 === calendarView }) else { throw MailError(message: "Warm calendar view was rebuilt") }
            guard calendarCache != nil else { throw MailError(message: "Calendar snapshot was discarded between toggles") }
            calendarTask?.cancel()
            await loadCalendar()
        }
    }

    func checkMedia(_ path: String, probe: MediaProbe = .validate) async throws {
        guard accounts.allSatisfy({ $0.provider == .local }) else { throw MailError(message: "Media probe requires a disposable local cache") }
        let mail: Mail = try await core.request(["command": CoreCommand.importMail.rawValue, "path": path], mode: .live)
        mailbox = .live
        account = "local"
        try await loadAccounts()
        await loadList()
        if let index = messages.firstIndex(where: { $0.id == mail.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        await finishSelection()
        guard current?.id == mail.id else { throw MailError(message: "Media probe selected the wrong message") }
        setReader(.html)
        try await layout.reader.finishHTML()
        try layout.reader.verifyImages(0)
        let reply: MediaReply = try await core.request(["command": CoreCommand.media.rawValue, "id": mail.id, "mode": BodyFetch.cached.rawValue], mode: .live)
        guard let manifest = reply.manifest, manifest.assets.count == 4, manifest.imageIDs.count == 1 else { throw MailError(message: "Media fixture lost metadata") }
        for asset in manifest.assets {
            let file: MediaFile = try await core.request(["command": CoreCommand.mediaFile.rawValue, "id": mail.id, "asset": asset.id, "preview": PreviewSize.thumbnail.rawValue], mode: .live, queue: .media)
            let image = try await core.mediaThumbnail(file)
            guard image.width > 0, image.height > 0 else { throw MailError(message: "Empty attachment thumbnail") }
        }
        media.attachments(mail, mode: .live)
        await media.finish()
        if let pdf = manifest.assets.first(where: { $0.mime == "application/pdf" }) {
            media.preview(pdf, mail: mail, mode: .live)
            await media.finish()
        }
        media.loadImages(mail, mode: .live)
        await media.finish()
        try await layout.reader.finishHTML()
        try await layout.reader.finishImages(1)
        setReader(.text)
        layout.reader.display(mail, mode: .html)
        try await layout.reader.finishHTML()
        try await layout.reader.finishImages(1)
        layout.reader.showNotice("Media probe complete")
        try layout.reader.verifyImages(0)
        if probe == .preview {
            setReader(.html)
            media.attachments(mail, mode: .live)
            await media.finish()
            if let pdf = manifest.assets.first(where: { $0.mime == "application/pdf" }) {
                media.preview(pdf, mail: mail, mode: .live)
                await media.finish()
            }
            media.loadImages(mail, mode: .live)
            await media.finish()
            try await layout.reader.finishHTML()
            await finishSelection()
        }
        print("MEDIA verified blocked defaults, local image delivery, image/PDF/DOCX/XLSX thumbnails and selection reset")
    }

    func checkCalendar(_ mode: CalendarProbe = .validate) async throws {
        if mode == .preview { setSection(.calendar); return }
        guard calendarView == nil else { throw MailError(message: "Calendar was created during mail startup") }
        setSection(.calendar)
        try calendarView?.selfTest()
        for _ in 0..<20 {
            let retired = NSHashTable<AnyObject>.weakObjects()
            if let view = calendarView { retired.add(view) }
            if let side = calendarSidebar { retired.add(side) }
            setSection(.mail)
            try await Task.sleep(for: .milliseconds(20))
            setSection(.calendar)
            guard retired.allObjects.contains(where: { $0 === calendarView }) else { throw MailError(message: "Warm calendar view was rebuilt") }
            layout.layoutSubtreeIfNeeded()
            layout.window?.displayIfNeeded()
        }
        let retired = NSHashTable<AnyObject>.weakObjects()
        if let view = calendarView { retired.add(view) }
        if let side = calendarSidebar { retired.add(side) }
        setSection(.mail)
        await calendarIdleTask?.value
        await Task.yield()
        guard retired.allObjects.isEmpty else {
            throw MailError(message: "Idle calendar view was retained: " + retired.allObjects.map { String(describing: type(of: $0)) }.joined(separator: ", "))
        }
    }

    func measureCalendar() async throws -> [String: Any] {
        let before = try MemoryProbe.snapshot()
        let start = ProcessInfo.processInfo.systemUptime
        setSection(.calendar)
        if mailbox == .live { calendarTask?.cancel(); await loadCalendar() }
        layout.layoutSubtreeIfNeeded()
        layout.window?.displayIfNeeded()
        CATransaction.flush()
        let opening = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var timings: [Double] = []
        for index in 0..<30 {
            try await Task.sleep(for: .milliseconds(33))
            let start = ProcessInfo.processInfo.systemUptime
            calendarView?.step(index % 2 == 0 ? 1 : -1)
            if mailbox == .live { calendarTask?.cancel(); await loadCalendar() }
            layout.layoutSubtreeIfNeeded()
            layout.window?.displayIfNeeded()
            CATransaction.flush()
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        try await Task.sleep(for: .seconds(2))
        let active = try MemoryProbe.snapshot()
        setSection(.mail)
        try await Task.sleep(for: Self.calendarIdleDelay + .milliseconds(200))
        let closed = try MemoryProbe.snapshot()
        setSection(.calendar)
        layout.layoutSubtreeIfNeeded()
        layout.window?.displayIfNeeded()
        var reopening: [Double] = []
        for _ in 0..<10 {
            setSection(.mail)
            let start = ProcessInfo.processInfo.systemUptime
            setSection(.calendar)
            calendarTask?.cancel()
            layout.layoutSubtreeIfNeeded()
            layout.window?.displayIfNeeded()
            CATransaction.flush()
            reopening.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(33))
        }
        setSection(.calendar)
        timings.sort()
        reopening.sort()
        return ["first_open_ms": opening, "month_navigation_p95_ms": timings[28],
                "cached_reopen_p95_ms": reopening[9],
                "mail_before": before, "calendar_active": active, "mail_after_close": closed]
    }

    @objc private func openAppUpdates() { AppUpdates.open() }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Square Mail 0.1"
        alert.informativeText = "Square Mail private preview.\n\nOffline mail caches, local drafts, reviewed queued sends and separately authorised mail/calendar changes. Remote images stay blocked until requested. Image/PDF/DOCX/XLSX previews download on request. The bell has bounded history. macOS alerts are opt-in. Plain-text forwarding omits attachments. Delete moves to Trash. Live write/delivery qualification remains pending.\n\nVisual references: Visual Basic and classic Outlook. No reference-project assets are bundled."
        WindowPresentation.runAlert(alert)
    }

    // A native integration probe exercises the same controller and bridge as the UI.
    func finishSelection() async {
        await readingTask?.value
        await layout.reader.finishText()
        layout.layoutSubtreeIfNeeded()
        layout.window?.displayIfNeeded()
        CATransaction.flush()
    }

    func measureSwitches(_ reader: ReaderMode = .text, samples: Int = 200, pattern: SwitchPattern = .sequential) async throws -> [String: Any] {
        guard messages.count > 1 else { throw MailError(message: "Switching requires two cached messages") }
        setReader(reader)
        var timings: [Double] = []
        var bodyTimings: [Double] = []
        var sizes: [Int] = []
        var growth: [String: Any] = [:]
        let checkpoints: Set<Int> = [100, 500, 1000]
        if samples >= 1000 {
            try await Task.sleep(for: .seconds(2))
            growth["0"] = try MemoryProbe.snapshot()
        }
        for step in 0..<samples {
            // Model 30 Hz navigation without building an artificial compositor backlog.
            try await Task.sleep(for: .milliseconds(33))
            let index = pattern == .visible ? 4 + step % 2 : (step + 1) % min(messages.count, 40)
            guard messages.indices.contains(index) else { throw MailError(message: "Visible-row probe needs six cached messages") }
            let start = ProcessInfo.processInfo.systemUptime
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            await readingTask?.value
            bodyTimings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            await finishSelection()
            if reader == .html { try await layout.reader.finishHTML(); await finishSelection() }
            guard current?.id == messages[index].id, current?.text != nil else {
                throw MailError(message: "Selection probe did not display the requested cached body")
            }
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            sizes.append(current?.text?.utf8.count ?? 0)
            if samples >= 1000, checkpoints.contains(step + 1) {
                try await Task.sleep(for: .seconds(2))
                growth[String(step + 1)] = try MemoryProbe.snapshot()
            }
        }
        timings.sort()
        bodyTimings.sort()
        return ["samples": samples, "selection_to_draw_submit_p50_ms": timings[samples / 2],
                "selection_to_draw_submit_p95_ms": timings[Int(Double(samples) * 0.95) - 1],
                "selection_to_body_ready_p95_ms": bodyTimings[Int(Double(samples) * 0.95) - 1],
                "selection_to_draw_submit_max_ms": timings.last ?? 0,
                "body_bytes_min": sizes.min() ?? 0, "body_bytes_max": sizes.max() ?? 0,
                "memory_checkpoints": growth, "row_views_created": rowViewsMade]
    }

    func measureHTMLIdle() async throws -> [String: Any] {
        setReader(.text)
        try await Task.sleep(for: .seconds(6))
        guard !layout.reader.hasHTMLRenderer else { throw MailError(message: "Idle HTML renderer was retained") }
        return ["html_renderer_released": true]
    }

    func checkPaging() async throws {
        guard messages.count == Self.pageSize, let first = messages.first?.id else {
            throw MailError(message: "Paging probe requires more than 500 generated messages")
        }
        await loadList(page: .older)
        guard pageOffset == Self.pageSize, messages.count == Self.pageSize, messages.first?.id != first else {
            throw MailError(message: "Older page did not replace the header window")
        }
        await loadList(page: .older)
        guard pageOffset == Self.pageSize * 2, messages.count < Self.pageSize else {
            throw MailError(message: "Last page exceeded the header budget")
        }
        await loadList(page: .newer)
        await loadList(page: .newer)
        guard pageOffset == 0, messages.first?.id == first else { throw MailError(message: "Newer pages did not restore the inbox") }
        await finishSelection()
    }

    func measureCache() async throws -> [String: Any] {
        guard let mail = messages.first else { throw MailError(message: "No cached mail to measure") }
        var timings: [Double] = []
        for _ in 0..<60 {
            let start = ProcessInfo.processInfo.systemUptime
            let _: Mail = try await core.request(["command": CoreCommand.message.rawValue, "id": mail.id, "mode": BodyFetch.cached.rawValue], mode: mailbox)
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        timings.sort()
        return ["cached_body_bridge_p95_ms": timings[56], "rows": messages.count,
                "html_renderer_created": layout.reader.hasHTMLRenderer]
    }

    private func verifyActionPlacement() throws {
        layout.layoutSubtreeIfNeeded()
        let actions = [replyButton, replyAllButton, forwardButton, archiveButton, trashButton, moveButton, readButton, flagButton, pinButton]
        guard actions.allSatisfy({ $0.superview === layout.messageActions }), layout.messageActions.superview === layout.readerPane,
              textButton.isDescendant(of: layout.reader), htmlButton.isDescendant(of: layout.reader),
              [mailButton, calendarButton, syncButton, draftsButton, splitButton].allSatisfy({ $0.superview === layout.toolbar }) else { throw MailError(message: "Message and global actions have mixed ownership") }
        for bar in [layout.messageActions, layout.toolbar] {
            let visible = bar.subviews.filter { !$0.isHidden }
            guard visible.allSatisfy({ bar.bounds.contains($0.frame) }) else { throw MailError(message: "Toolbar action escaped its pane") }
            for (index, view) in visible.enumerated() {
                guard visible.dropFirst(index + 1).allSatisfy({ !view.frame.intersects($0.frame) }) else { throw MailError(message: "Toolbar buttons overlap") }
            }
        }
        guard layout.header.frame.minY >= layout.messageActions.frame.maxY,
              layout.reader.frame.minY >= layout.header.frame.maxY else { throw MailError(message: "Message controls overlap headers or content") }
        try layout.reader.verifyControlLayout()
        let overflow = layout.messageActions.overflowMenu()
        if readButton.isHidden {
            guard let item = overflow.items.first(where: { $0.title == readButton.title }), item.isEnabled == readButton.isEnabled else { throw MailError(message: "Overflow lost the current message state") }
        }
    }

    private func checkReadingLayouts() async throws {
        let original = readingLayout
        let divider = layout.split.isVertical ? layout.listPane.frame.width : layout.listPane.frame.height
        let selection = current?.id
        let size = layout.window!.contentView!.bounds.size
        defer {
            layout.window?.setContentSize(size)
            layout.layoutSubtreeIfNeeded()
            setReadingLayout(original, save: .transient)
            layout.split.setPosition(divider, ofDividerAt: 0)
        }
        for value in [ReadingLayout.right, .below, .right, .below] {
            setReadingLayout(value, save: .transient)
            await finishSelection()
            guard current?.id == selection, table.numberOfRows == messages.count, table.selectedRow >= 0 else {
                throw MailError(message: "Reading layout changed the selected message or page")
            }
            if value == .right {
                guard let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? MessageSummaryCell,
                      let mail = current else { throw MailError(message: "Compact message row is missing") }
                let labels = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                guard labels.contains(mail.displaySubject), labels.contains(MessagePreview.render(mail.preview).text) else {
                    throw MailError(message: "Compact row lost its subject or preview")
                }
            }
            for size in [NSSize(width: 1060, height: 730), NSSize(width: 1400, height: 920)] {
                layout.window?.setContentSize(size)
                layout.layoutSubtreeIfNeeded()
                for position: CGFloat in value == .below ? [180, 480, 250] : [300, 480, 350] {
                    layout.split.setPosition(position, ofDividerAt: 0)
                    layout.layoutSubtreeIfNeeded()
                    try verifyActionPlacement()
                    guard abs(layout.listScroll.frame.maxY - (layout.listPane.bounds.height - 2)) < 1,
                          abs(layout.reader.frame.maxY - (layout.readerPane.bounds.height - 2)) < 1,
                          abs(layout.listScroll.frame.width - (layout.listPane.bounds.width - 4)) < 1,
                          abs(layout.reader.frame.width - (layout.readerPane.bounds.width - 4)) < 1 else {
                        throw MailError(message: "Divider left stale mail or reader viewport bounds")
                    }
                }
            }
        }
    }

    func selfTest() async throws -> [String: Any] {
        guard messages.count == 40 else { throw MailError(message: "Demo inbox did not load") }
        try await layout.reader.verifyLoading()
        try await layout.reader.verifyLinks()
        await layout.reader.finishText()
        try await checkReadingLayouts()
        let initial = messages[0]
        let body: Mail = try await core.request(["command": CoreCommand.message.rawValue, "id": initial.id, "mode": BodyFetch.cached.rawValue], mode: .demo)
        guard body.text?.contains("quiet inbox") == true else { throw MailError(message: "Body round trip failed") }
        setSearchText("machine")
        await loadList()
        guard !messages.isEmpty, messages.allSatisfy({ $0.subject.contains("machine") }) else {
            throw MailError(message: "Native search did not filter the mailbox")
        }
        setSearchText("")
        await loadList()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await finishSelection()
        guard current?.id == messages[2].id else { throw MailError(message: "A stale selection replaced the current message") }
        _ = try await measureSwitches(samples: 40)
        let warmRows = rowViewsMade
        _ = try await measureSwitches(samples: 40)
        guard rowViewsMade == warmRows else { throw MailError(message: "Row views grew while revisiting the same messages") }
        setReader(.html)
        layout.reader.display(body, mode: .html)
        try await layout.reader.finishHTML()
        guard !HTMLPolicy.permitsLink(URL(string: "file:///etc/passwd")!),
              !HTMLPolicy.permitsLink(URL(string: "javascript:alert(1)")!),
              HTMLPolicy.contentPolicy.contains("default-src 'none'") else {
            throw MailError(message: "HTML navigation policy failed")
        }
        setReader(.text)
        _ = try await measureHTMLIdle()
        setReader(.html)
        layout.reader.display(body, mode: .html)
        try await layout.reader.finishHTML()
        guard layout.reader.hasHTMLRenderer else { throw MailError(message: "HTML could not reopen after idle release") }
        setReader(.text)
        return ["native_search": true, "body_roundtrip": true, "passive_html": true,
                "latest_selection": true, "html_release_and_reopen": true,
                "bounded_row_views": true,
                "reading_layouts": true,
                "main_thread_io": false, "mailbox_rows": messages.count]
    }
}
