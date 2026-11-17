import AppKit
import ClassicKit

@MainActor
final class MailController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let core: MailCore
    private let layout: MailLayout
    private let table = NSTableView()
    private let sidebar = Sidebar()
    private var messages: [Mail] = []
    private var accounts: [Account] = []
    private var folder: Folder = .inbox
    private var account: String?
    private var mailbox: MailboxMode = .demo
    private var readerMode: ReaderMode = .text
    private var current: Mail?
    private var listRevision = 0
    private var bodyRevision = 0
    private var searchTask: Task<Void, Never>?
    private var syncing = false
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
    private var mailSearch = ""
    private let calendarButton = ClassicButton("Calendar", icon: .calendar, style: .toolbar)
    private let importButton = ClassicButton("Import .eml", icon: .folder, style: .toolbar)
    private static let offlineArgs: Set<String> = ["--perf-report", "--self-test", "--check-paging", "--metrics", "--check-calendar"]
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
        super.init()
        buildSidebar()
        buildToolbar()
        buildTable()
        buildMenus()
        layout.search.delegate = self
    }

    func start() async {
        do {
            let live: [Account] = try await core.request(["command": "accounts"], mode: .live)
            mailbox = live.isEmpty ? .demo : .live
            if mailbox == .demo {
                let _: EmptyReply = try await core.request(["command": "seed_demo"], mode: .demo)
            }
            try await loadAccounts()
            await loadList()
        } catch { showError(error) }
    }

    private func buildSidebar() {
        sidebar.frame = layout.sidebar.bounds.insetBy(dx: 2, dy: 2)
        sidebar.autoresizingMask = [.width, .height]
        layout.sidebar.addSubview(sidebar)
        sidebar.onFolder = { [weak self] folder in
            guard let self else { return }
            self.folder = folder
            self.sidebar.select(folder)
            self.layout.folderLabel.stringValue = folder.title
            self.layout.titleBar.title = "Square Mail - \(folder.title)"
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

    private func buildTable() {
        let columns: [(String, String, CGFloat)] = [
            ("status", "", 30), ("sender", "From", 195), ("subject", "Subject", 480),
            ("date", "Received", 145), ("account", "Account", 160)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "status" ? 30 : 80
            column.headerCell = ClassicHeaderCell(textCell: title)
            table.addTableColumn(column)
        }
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
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
    }

    private func loadAccounts() async throws {
        accounts = try await core.request(["command": "accounts"], mode: mailbox)
        sidebar.accounts.removeAllItems()
        sidebar.accounts.addItem(withTitle: "All accounts")
        for value in accounts {
            sidebar.accounts.addItem(withTitle: value.email)
            sidebar.accounts.lastItem?.representedObject = value.id
        }
        if let account, let index = accounts.firstIndex(where: { $0.id == account }) {
            sidebar.accounts.selectItem(at: index + 1)
        } else { account = nil }
        sidebar.demo.title = mailbox == .demo ? "My mailbox" : "Demo mailbox"
        layout.statusMode.stringValue = mailbox == .demo ? "LOCAL DEMO" : "LOCAL CACHE"
    }

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
        current = nil
        layout.header.display(nil)
        layout.reader.showNotice("Loading local messages…")
        let command: [String: Any] = [
            "command": "list", "account": account as Any? ?? NSNull(), "folder": folder.rawValue,
            "query": layout.search.stringValue, "offset": offset, "limit": Self.pageSize
        ]
        do {
            let page: [Mail] = try await core.request(command, mode: mailbox)
            guard revision == listRevision else { return }
            messages = page
            pageOffset = offset
            table.reloadData()
            more.isEnabled = page.count == Self.pageSize
            newer.isEnabled = pageOffset > 0
            layout.listCaption.stringValue = "\(folder.title.uppercased())  ·  \(messages.isEmpty ? "0" : "\(offset + 1)-\(offset + messages.count)") SHOWN"
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
            layout.statusText.stringValue = "Could not read the local mailbox"
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
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ClassicTableCell) ?? ClassicTableCell()
        cell.identifier = id
        let mail = messages[row]
        let weight: ClassicTheme.Weight = mail.unread ? .bold : .regular
        switch id.rawValue {
        case "status": cell.configure("", icon: mail.starred ? .star : (mail.unread ? .mail : nil))
        case "sender": cell.configure(mail.sender.isEmpty ? mail.senderAddress : mail.sender, weight: weight)
        case "subject": cell.configure(mail.subject, weight: weight, icon: mail.hasAttachments ? .attach : nil)
        case "date": cell.configure(dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(mail.timestamp))))
        case "account": cell.configure(accounts.first(where: { $0.id == mail.accountId })?.email ?? "")
        default: break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard section == .mail else { return }
        guard messages.indices.contains(table.selectedRow) else { return }
        let summary = messages[table.selectedRow]
        bodyRevision += 1
        let revision = bodyRevision
        let mode = mailbox
        readingTask = Task {
            do {
                var mail: Mail = try await core.request(["command": "message", "id": summary.id, "mode": "cached"], mode: mode)
                guard revision == bodyRevision else { return }
                if mail.text == nil {
                    let arguments = ProcessInfo.processInfo.arguments
                    if !Self.offlineArgs.isDisjoint(with: arguments) {
                        throw MailError(message: "Offline probes require a cached message body")
                    }
                    current = summary
                    layout.header.display(summary)
                    layout.reader.showNotice("Downloading message body…")
                    mail = try await core.request(["command": "message", "id": summary.id, "mode": "fetch"], mode: mode, queue: .network)
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
        account = sidebar.accounts.selectedItem?.representedObject as? String
        Task { await loadList() }
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
        bodyRevision += 1
        mailbox = mailbox == .demo ? .live : .demo
        account = nil
        Task {
            do {
                if mailbox == .demo { let _: EmptyReply = try await core.request(["command": "seed_demo"], mode: .demo) }
                try await loadAccounts()
                await loadList()
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
                    let _: Mail = try await core.request(["command": "import", "path": file.path], mode: .live)
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
        guard section == .mail else { return }
        guard !syncing else { return }
        let active = accounts.filter { $0.provider != .local && (account == nil || $0.id == account) }
        guard !active.isEmpty else {
            if mailbox == .demo { layout.statusText.stringValue = "Demo mailbox is local. Connect an account to sync." }
            else { connectAccount() }
            return
        }
        syncing = true
        syncButton.isEnabled = false
        let mode = mailbox
        let syncFolder = folder
        layout.statusText.stringValue = "Syncing latest headers… You can keep reading."
        Task {
            defer { syncing = false; syncButton.isEnabled = section == .mail }
            do {
                var count = 0
                for value in active {
                    let reply: SyncReply = try await core.request(["command": "sync", "account": value.id, "folder": syncFolder.rawValue], mode: mode, queue: .network)
                    count += reply.count
                }
                await loadList()
                layout.statusText.stringValue = "Synced \(count) headers. Bodies download when opened."
            } catch { showError(error) }
        }
    }

    @objc private func connectAccount() {
        let dialog = AccountDialog()
        guard let input = dialog.run() else { return }
        layout.statusText.stringValue = "Waiting for browser sign-in. This attempt expires in three minutes."
        sidebar.connect.isEnabled = false
        Task {
            defer { sidebar.connect.isEnabled = true }
            do {
                let command: [String: Any] = ["command": "connect", "provider": input.provider.rawValue,
                    "client_id": input.clientId, "client_secret": input.clientSecret]
                let value: Account = try await core.request(command, mode: .live, queue: .network)
                mailbox = .live; account = value.id
                try await loadAccounts()
                await loadList()
                syncMail()
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

    private func setSection(_ next: Section) {
        guard next != section else { return }
        searchTask?.cancel()
        section = next
        textButton.isEnabled = next == .mail
        importButton.isEnabled = next == .mail
        htmlButton.isEnabled = next == .mail
        syncButton.isEnabled = next == .mail && !syncing
        if next == .calendar {
            listRevision += 1
            bodyRevision += 1
            mailSearch = layout.search.stringValue
            layout.split.isHidden = true
            sidebar.isHidden = true
            layout.reader.pause()
            let view = CalendarView(state: calendarState)
            let side = CalendarSidebar(state: calendarState)
            view.frame = layout.split.frame
            view.autoresizingMask = [.width, .height]
            side.frame = layout.sidebar.bounds.insetBy(dx: 2, dy: 2)
            side.autoresizingMask = [.width, .height]
            side.onDate = { [weak view] date in view?.selectDate(date) }
            side.onFeeds = { [weak view] feeds in view?.setFeeds(feeds) }
            side.onMail = { [weak self] in self?.setSection(.mail) }
            view.onDateChanged = { [weak side] date in side?.showDate(date) }
            layout.addSubview(view)
            layout.sidebar.addSubview(side)
            calendarView = view
            calendarSidebar = side
            calendarButton.title = "Mail"
            calendarButton.icon = .mail
            layout.folderLabel.stringValue = "Calendar"
            layout.titleBar.title = "Square Mail - Calendar"
            layout.search.stringValue = calendarState.query
            layout.search.placeholderString = "Search sample events (⌘F)"
            layout.statusText.stringValue = "Sample calendars · Google, Outlook.com / Live, Microsoft 365"
            layout.statusMode.stringValue = "LOCAL DEMO"
            layout.statusReader.stringValue = "CALENDAR"
        } else {
            if let view = calendarView { calendarState = view.state }
            calendarView?.removeFromSuperview(); calendarView = nil
            calendarSidebar?.removeFromSuperview(); calendarSidebar = nil
            layout.split.isHidden = false
            sidebar.isHidden = false
            calendarButton.title = "Calendar"
            calendarButton.icon = .calendar
            layout.folderLabel.stringValue = folder.title
            layout.titleBar.title = "Square Mail - \(folder.title)"
            layout.search.stringValue = mailSearch
            layout.search.placeholderString = "Search this folder (⌘F)"
            layout.statusText.stringValue = "\(messages.count) messages shown · Cached on this Mac"
            layout.statusMode.stringValue = mailbox == .demo ? "LOCAL DEMO" : "LOCAL CACHE"
            setReader(readerMode)
            Task { await loadList() }
        }
        layout.titleBar.needsDisplay = true
        layout.search.setAccessibilityLabel(next == .calendar ? "Search sample events" : "Search this folder")
        calendarButton.setAccessibilityLabel(calendarButton.title)
        calendarButton.needsDisplay = true
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
            guard retired.allObjects.isEmpty else { throw MailError(message: "Closed calendar views were retained") }
            setSection(.calendar)
            layout.layoutSubtreeIfNeeded()
            layout.window?.displayIfNeeded()
        }
        setSection(.mail)
    }

    func measureCalendar() async throws -> [String: Any] {
        let before = try MemoryProbe.snapshot()
        let start = ProcessInfo.processInfo.systemUptime
        setSection(.calendar)
        layout.layoutSubtreeIfNeeded()
        layout.window?.displayIfNeeded()
        CATransaction.flush()
        let opening = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var timings: [Double] = []
        for index in 0..<30 {
            try await Task.sleep(for: .milliseconds(33))
            let start = ProcessInfo.processInfo.systemUptime
            calendarView?.step(index % 2 == 0 ? 1 : -1)
            layout.layoutSubtreeIfNeeded()
            layout.window?.displayIfNeeded()
            CATransaction.flush()
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        try await Task.sleep(for: .seconds(2))
        let active = try MemoryProbe.snapshot()
        setSection(.mail)
        try await Task.sleep(for: .seconds(2))
        let closed = try MemoryProbe.snapshot()
        setSection(.calendar)
        timings.sort()
        return ["first_open_ms": opening, "month_navigation_p95_ms": timings[28],
                "mail_before": before, "calendar_active": active, "mail_after_close": closed]
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Square Mail 0.1"
        alert.informativeText = "Native AppKit reader. Rust mail core.\n\nAn early, read-only client. Sync caches the latest 200 headers per selected folder. HTML blocks scripts and remote content. Attachments, sending and full-history sync are not implemented.\n\nVisual references: Visual Basic and classic Outlook. No reference-project assets are bundled."
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
            let _: Mail = try await core.request(["command": "message", "id": mail.id, "mode": "cached"], mode: mailbox)
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        timings.sort()
        return ["cached_body_bridge_p95_ms": timings[56], "rows": messages.count,
                "html_renderer_created": layout.reader.hasHTMLRenderer]
    }

    func selfTest() async throws -> [String: Any] {
        guard messages.count == 40 else { throw MailError(message: "Demo inbox did not load") }
        let initial = messages[0]
        let body: Mail = try await core.request(["command": "message", "id": initial.id, "mode": "cached"], mode: .demo)
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
                "main_thread_io": false, "mailbox_rows": messages.count]
    }
}
