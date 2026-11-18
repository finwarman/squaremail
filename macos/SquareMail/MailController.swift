import AppKit
import ClassicKit

@MainActor
final class MailController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
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
    private var current: Mail?
    private var listRevision = 0
    private var bodyRevision = 0
    private var searchTask: Task<Void, Never>?
    private var pendingCatalog = false
    private var networkAvailable = true
    private var networkReady = false
    private var readingTask: Task<Void, Never>?
    private var rowViewsMade = 0
    private static let rowReuseID = NSUserInterfaceItemIdentifier("mail-row")
    private static let pageSize = 250
    private var pageOffset = 0
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
    private let importButton = ClassicButton("Import .eml", icon: .folder, style: .toolbar)
    private static let offlineArgs: Set<String> = ["--perf-report", "--self-test", "--check-paging", "--metrics", "--check-calendar", "--check-accounts", "--check-media", "--check-calendar-actions"]
    private let textButton = ClassicButton("Text only", icon: .text, style: .toggle)
    private let htmlButton = ClassicButton("HTML", icon: .html, style: .toggle)
    private let more = ClassicButton("Older")
    private let newer = ClassicButton("Newer")
    private let syncButton = ClassicButton("Sync", icon: .sync, style: .toolbar)
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
        layout.reader.onImageState = { [weak self] permission in
            guard let self else { return }
            self.layout.header.images = permission
            if self.readerMode == .html { self.layout.statusReader.stringValue = permission == .loaded ? "HTML · IMAGES LOADED" : "HTML · REMOTE OFF" }
        }
        layout.search.delegate = self
        coordinator.onChange = { [weak self] reply in self?.syncChanged(reply) }
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
        noticeTask?.cancel(); noticeTask = nil
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
            self.layout.search.stringValue = ""
            Task { await self.loadList() }
        }
        sidebar.onRemoteFolder = { [weak self] folder in
            guard let self else { return }
            self.noticeTask?.cancel()
            self.remoteFolder = folder
            self.layout.folderLabel.stringValue = folder.name
            self.layout.titleBar.title = "Square Mail - " + folder.name
            self.layout.titleBar.needsDisplay = true
            self.layout.search.stringValue = ""
            Task { await self.loadList() }
        }
        sidebar.accounts.target = self
        sidebar.accounts.action = #selector(changeAccount)
        sidebar.connect.onPress = { [weak self] in self?.connectAccount() }
        sidebar.demo.onPress = { [weak self] in self?.toggleDemo() }
    }

    private func buildToolbar() {
        let accountsButton = ClassicButton("Accounts", icon: .account, style: .toolbar)
        let previous = ClassicButton("Previous", icon: .mail, style: .toolbar)
        let next = ClassicButton("Next", icon: .mail, style: .toolbar)
        importButton.onPress = { [weak self] in self?.importMail() }
        syncButton.onPress = { [weak self] in self?.syncMail() }
        accountsButton.onPress = { [weak self] in self?.connectAccount() }
        previous.onPress = { [weak self] in self?.moveSelection(-1) }
        next.onPress = { [weak self] in self?.moveSelection(1) }
        for (index, button) in [importButton, syncButton, accountsButton, previous, next].enumerated() {
            button.frame = NSRect(x: 6 + index * 78, y: 3, width: 76, height: 55)
            layout.toolbar.addSubview(button)
        }
        textButton.frame = NSRect(x: 416, y: 17, width: 106, height: 28)
        htmlButton.frame = NSRect(x: 527, y: 17, width: 86, height: 28)
        textButton.onPress = { [weak self] in self?.setReader(.text) }
        htmlButton.onPress = { [weak self] in self?.setReader(.html) }
        layout.toolbar.addSubview(textButton)
        layout.toolbar.addSubview(htmlButton)
        calendarButton.frame = NSRect(x: 635, y: 3, width: 80, height: 55)
        calendarButton.onPress = { [weak self] in self?.toggleCalendar() }
        layout.toolbar.addSubview(calendarButton)
        splitButton.frame = NSRect(x: 735, y: 17, width: 110, height: 28)
        splitButton.toolTip = "Switch between a reading pane below the list or on its right"
        splitButton.onPress = { [weak self] in
            guard let self else { return }
            self.setReadingLayout(self.readingLayout == .below ? .right : .below)
        }
        layout.toolbar.addSubview(splitButton)
        bell.frame = NSRect(x: 855, y: 3, width: 90, height: 55)
        bell.onPress = { [weak self] in self?.noticeService().show() }
        layout.toolbar.addSubview(bell)
        cancelLogin.frame = NSRect(x: 950, y: 17, width: 90, height: 28)
        cancelLogin.isHidden = true
        cancelLogin.onPress = { [weak self] in
            self?.connectTask?.cancel()
            self?.cancelLogin.isEnabled = false
            self?.layout.statusText.stringValue = "Cancelling sign-in…"
        }
        layout.toolbar.addSubview(cancelLogin)
        textButton.state = .on
        more.frame = NSRect(x: layout.listPane.bounds.width - 76, y: 4, width: 67, height: 22)
        more.autoresizingMask = [.minXMargin]
        more.onPress = { [weak self] in Task { await self?.loadList(page: .older) } }
        layout.listPane.addSubview(more)
        newer.frame = NSRect(x: layout.listPane.bounds.width - 148, y: 4, width: 67, height: 22)
        newer.autoresizingMask = [.minXMargin]
        newer.onPress = { [weak self] in Task { await self?.loadList(page: .newer) } }
        layout.listPane.addSubview(newer)
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
        ["command": CoreCommand.list.rawValue, "account": account as Any? ?? NSNull(), "folder": folder.rawValue,
         "folder_id": remoteFolder?.id as Any? ?? NSNull(), "query": layout.search.stringValue,
         "offset": pageOffset, "limit": Self.pageSize]
    }
    private var folderTitle: String { remoteFolder?.name ?? folder.title }
    private enum ListPage { case start, older, newer }

    private func loadList(page direction: ListPage = .start) async {
        listRevision += 1
        let revision = listRevision
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
            let page: [Mail] = try await core.request(command, mode: mailbox)
            guard revision == listRevision else { return }
            table.deselectAll(nil)
            messages = page
            pageOffset = offset
            table.reloadData()
            more.isEnabled = page.count == Self.pageSize
            newer.isEnabled = pageOffset > 0
            layout.listCaption.stringValue = "\(folderTitle.uppercased())  ·  \(messages.isEmpty ? "0" : "\(offset + 1)-\(offset + messages.count)") SHOWN"
            layout.statusText.stringValue = "\(messages.count) messages  ·  \(messages.filter(\.unread).count) unread  ·  \(mailbox == .demo ? "Demo data" : "Cached on this Mac")"
            if !messages.isEmpty {
                let index = selected.flatMap { id in messages.firstIndex(where: { $0.id == id }) } ?? 0
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                layout.reader.showNotice(mailbox == .demo ? "No messages match this view." : "No cached messages. Connect an account, then choose Sync.")
            }
        } catch {
            guard revision == listRevision else { return }
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
        case .sender: cell.configure(mail.sender.isEmpty ? mail.senderAddress : mail.sender, weight: weight)
        case .subject: cell.configure(mail.subject, weight: weight, icon: mail.hasAttachments ? .attach : nil)
        case .date: cell.configure(dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(mail.timestamp))))
        case .account: cell.configure(accounts.first(where: { $0.id == mail.accountId })?.email ?? "")
        default: break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard section == .mail else { return }
        guard messages.indices.contains(table.selectedRow) else { return }
        readMessage(messages[table.selectedRow])
    }

    private func readMessage(_ summary: Mail) {
        readingTask?.cancel()
        bodyRevision += 1
        let revision = bodyRevision
        let mode = mailbox
        readingTask = Task {
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
                    guard networkReady else { layout.reader.showNotice("This body has not been downloaded yet."); return }
                    guard networkAvailable else { throw MailError(message: "Offline. Open this message while online to cache its body.") }
                    layout.reader.showNotice("Downloading message body…")
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
                layout.reader.showNotice("This body is not cached.\n\n\(error.localizedDescription)")
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
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
        guard panel.runModal() == .OK else { return }
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
                layout.search.stringValue = ""
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
        startSync()
        coordinator.requestRefresh()
        layout.statusText.stringValue = "Sync requested. Cached mail and calendars remain available."
    }

    private func syncChanged(_ reply: SyncStep) {
        guard mailbox == .live else { return }
        if let error = reply.error {
            let email = accounts.first(where: { $0.id == reply.accountId })?.email ?? "Account"
            layout.statusText.stringValue = email + ": " + error
            return
        }
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
            let rows: [Mail] = try await core.request(command, mode: mailbox)
            guard !Task.isCancelled, revision == listRevision, section == .mail, rows != messages else { return }
            let selected = current?.id
            table.deselectAll(nil)
            messages = rows
            table.reloadData()
            more.isEnabled = rows.count == Self.pageSize
            if let id = selected, let index = rows.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            else { current = nil; layout.header.display(nil); layout.reader.showNotice("No cached messages in this view.") }
            layout.statusText.stringValue = "Cache updated · " + String(rows.count) + " messages shown"
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
            guard panel.runModal() == .OK, let url = panel.url else { return }
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
        let alert = NSAlert()
        alert.messageText = "Disconnect this account?"
        alert.informativeText = "Remove saved tokens. Keep downloaded mail and calendar data for offline reading, or remove this account's local cache. Provider data is unchanged."
        alert.addButton(withTitle: "Keep offline cache")
        alert.addButton(withTitle: "Remove local cache")
        alert.addButton(withTitle: "Cancel")
        let reply = alert.runModal()
        guard reply == .alertFirstButtonReturn || reply == .alertSecondButtonReturn else { return }
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
        alert.runModal()
    }

    private func buildMenus() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Square Mail", action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Square Mail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Square Mail", action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: "File")
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
        let tools = NSMenu(title: "Tools")
        addItem(tools, "Sync current folder", #selector(syncMail), "r")
        let help = NSMenu(title: "Help")
        addItem(help, "About this preview", #selector(showAbout), "")
        for menu in [file, edit, view, tools, help] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        for item in app.items where item.action == #selector(showAbout) { item.target = self }
        NSApp.mainMenu = main
        var x: CGFloat = 0
        for menu in [file, edit, view, tools, help] {
            let button = ClassicButton(menu.title, style: .menu)
            button.frame = NSRect(x: x, y: 0, width: 48, height: 24)
            button.onPress = { [weak button] in
                guard let button else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
            layout.menus.addSubview(button)
            x += 48
        }
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    @objc private func focusSearch() { layout.window?.makeFirstResponder(layout.search) }
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
        textButton.isEnabled = next == .mail
        importButton.isEnabled = next == .mail
        htmlButton.isEnabled = next == .mail
        splitButton.isEnabled = next == .mail
        syncButton.isEnabled = true
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
            calendarSidebar = side
            calendarButton.title = "Mail"
            calendarButton.icon = .mail
            layout.folderLabel.stringValue = "Calendar"
            layout.titleBar.title = "Square Mail - Calendar"
            layout.search.stringValue = calendarState.query
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
            calendarButton.title = "Calendar"
            calendarButton.icon = .calendar
            layout.folderLabel.stringValue = folderTitle
            layout.titleBar.title = "Square Mail - \(folderTitle)"
            layout.search.stringValue = mailSearch
            layout.search.placeholderString = "Search this folder (⌘F)"
            layout.statusText.stringValue = "\(messages.count) messages shown · Cached on this Mac"
            layout.statusMode.stringValue = mailbox == .demo ? "LOCAL DEMO" : "LOCAL CACHE"
            setReader(readerMode)
            if reload == .refresh { Task { await loadList() } }
        }
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
                layout.search.stringValue = ""
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
            layout.search.stringValue = ""
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
            layout.search.stringValue = value.id + " project"
            await loadList()
            guard !messages.isEmpty, messages.allSatisfy({ $0.accountId == value.id }) else { throw MailError(message: "Scoped search lost account isolation") }
        }
        account = nil; remoteFolder = nil; layout.search.stringValue = ""
        await loadList()
        guard Set(messages.map(\.accountId)).count == 3 else { throw MailError(message: "Unified inbox omitted an account") }
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

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Square Mail 0.1"
        alert.informativeText = "Native AppKit reader. Rust mail core.\n\nA mail reader with offline caches, automatic sync and separately authorised calendar edits. Remote images stay blocked until requested. Image/PDF/DOCX/XLSX previews download on request. The bell has bounded history. macOS alerts are opt-in. Mail sending is not implemented.\n\nVisual references: Visual Basic and classic Outlook. No reference-project assets are bundled."
        alert.runModal()
    }

    // A native integration probe exercises the same controller and bridge as the UI.
    func finishSelection() async {
        await readingTask?.value
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
                guard labels.contains(mail.subject), labels.contains(mail.preview) else {
                    throw MailError(message: "Compact row lost its subject or preview")
                }
            }
            for size in [NSSize(width: 1060, height: 730), NSSize(width: 1400, height: 920)] {
                layout.window?.setContentSize(size)
                layout.layoutSubtreeIfNeeded()
                for position: CGFloat in value == .below ? [180, 480, 250] : [300, 480, 350] {
                    layout.split.setPosition(position, ofDividerAt: 0)
                    layout.layoutSubtreeIfNeeded()
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
        try await checkReadingLayouts()
        let initial = messages[0]
        let body: Mail = try await core.request(["command": CoreCommand.message.rawValue, "id": initial.id, "mode": BodyFetch.cached.rawValue], mode: .demo)
        guard body.text?.contains("quiet inbox") == true else { throw MailError(message: "Body round trip failed") }
        layout.search.stringValue = "machine"
        await loadList()
        guard !messages.isEmpty, messages.allSatisfy({ $0.subject.contains("machine") }) else {
            throw MailError(message: "Native search did not filter the mailbox")
        }
        layout.search.stringValue = ""
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
