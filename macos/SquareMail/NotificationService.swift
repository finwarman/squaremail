import AppKit
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let core: MailCore
    private let center = UNUserNotificationCenter.current()
    private var permissionTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var previewMode = false
    private var loop: Task<Void, Never>?
    private var lastPoll: ContinuousClock.Instant?
    private static let pollSpacing: Duration = .seconds(1)
    private var dirty = false
    private var refreshTask: Task<Void, Never>?
    private var panel: NotificationPanel?
    private var batch: NoticeBatch?
    private var accounts: [Account] = []
    private var active = false
    private var generation = 0
    private static let desktopKey = "desktopNotifications"
    private var desktop = UserDefaults.standard.bool(forKey: desktopKey)
    private var authorization: NotificationPermission = .notAsked
    private var permission: Bool { authorization == .allowed }
    private var planned: [String: Int64] = [:]
    var onCount: ((Int) -> Void)?
    var onOpen: ((AppNotice) -> Void)?
    var onStatus: ((String) -> Void)?

    init(core: MailCore) { self.core = core; super.init(); center.delegate = self }
    func start(_ accounts: [Account]) {
        self.accounts = accounts
        previewMode = false
        active = true
        if loop != nil { refresh(); return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func stop() {
        active = false; generation += 1
        loop?.cancel(); loop = nil
        refreshTask?.cancel(); refreshTask = nil
        actionTask?.cancel(); actionTask = nil; permissionTask?.cancel(); permissionTask = nil
        panel?.close(); panel = nil
    }
    func refresh() {
        guard active else { return }
        guard refreshTask == nil else { dirty = true; return }
        let revision = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshTask = nil
                if dirty { dirty = false; refresh() }
            }
            do {
                if let lastPoll {
                    let deadline = lastPoll + Self.pollSpacing
                    if ContinuousClock.now < deadline { try await Task.sleep(until: deadline, clock: .continuous) }
                }
                try Task.checkCancellation()
                lastPoll = .now
                dirty = false
                if !previewMode {
                    let status = await center.notificationSettings()
                    switch status.authorizationStatus {
                    case .authorized, .provisional: authorization = .allowed
                    case .denied: authorization = .denied
                    default: authorization = .notAsked
                    }
                } else { authorization = .notAsked }
                let delivery: NoticeDelivery = desktop && permission ? .desktop : .quiet
                let value: NoticeBatch = try await core.request(["command": CoreCommand.notices.rawValue, "delivery": delivery.rawValue], mode: .live, queue: .notifications)
                guard !Task.isCancelled, generation == revision else { return }
                batch = value
                onCount?(value.items.filter(\.unread).count)
                panel?.show(value, accounts: accounts, desktop: delivery, permission: authorization)
                if permissionTask != nil { panel?.permissionPending() }
                if actionTask != nil { panel?.setCommandState(.busy) }
                if delivery == .desktop && !previewMode {
                    for item in value.banners { try await submit(item) }
                    await trimDelivered()
                    try await schedule(value.planned)
                } else if !previewMode { await removePlans() }
            } catch is CancellationError {} catch { report(error.localizedDescription) }
        }
    }
    func show() {
        if panel == nil {
            let view = NotificationPanel()
            view.onAction = { [weak self] action in self?.perform(action) }
            view.onOpen = { [weak self] item in self?.onOpen?(item); self?.act(.read, id: item.id) }
            view.onDesktop = { [weak self] in self?.enableDesktop() }
            view.onPreference = { [weak self] account, channel, toggle in self?.setPreference(account, channel: channel, toggle: toggle) }
            panel = view
        }
        if let batch { panel?.show(batch, accounts: accounts, desktop: desktop && permission ? .desktop : .quiet, permission: authorization) }
        if actionTask != nil { panel?.setCommandState(.busy) }
        if permissionTask != nil { panel?.permissionPending() }
        panel?.open()
        refresh()
    }
    func preview(_ value: NoticeBatch, accounts: [Account]) {
        batch = value; self.accounts = accounts; active = true; previewMode = true
        onCount?(value.items.filter(\.unread).count)
        show()
    }
    private func perform(_ action: NoticeAction) { act(action, id: nil) }
    private func report(_ message: String) { onStatus?(message); panel?.showStatus(message) }
    private func act(_ action: NoticeAction, id: String?) {
        guard actionTask == nil else { return }
        panel?.setCommandState(.busy)
        let revision = generation
        actionTask = Task {
            defer { if generation == revision { actionTask = nil; panel?.setCommandState(.ready); refresh() } }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.noticeAction.rawValue, "action": action.rawValue, "id": id as Any? ?? NSNull()], mode: .live, queue: .notifications)
            } catch is CancellationError {} catch { report(error.localizedDescription) }
        }
    }
    private func setPreference(_ account: String?, channel: NoticeChannel, toggle: NoticeToggle) {
        guard actionTask == nil else { return }
        panel?.setCommandState(.busy)
        let revision = generation
        actionTask = Task {
            defer { if generation == revision { actionTask = nil; panel?.setCommandState(.ready); refresh() } }
            do {
                let _: EmptyReply = try await core.request(["command": CoreCommand.noticeSetting.rawValue, "account": account as Any? ?? NSNull(), "channel": channel.rawValue, "toggle": toggle.rawValue], mode: .live, queue: .notifications)
            } catch is CancellationError {} catch { report(error.localizedDescription) }
        }
    }
    private func enableDesktop() {
        guard permissionTask == nil else { return }
        if previewMode { report("Desktop alerts are disabled in the offline preview."); return }
        if desktop { desktop = false; UserDefaults.standard.set(false, forKey: Self.desktopKey); refresh(); return }
        if authorization == .denied {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            report("Enable Square Mail in System Settings → Notifications.")
            return
        }
        panel?.permissionPending()
        let revision = generation
        permissionTask = Task {
            defer { if generation == revision { permissionTask = nil; refresh() } }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard generation == revision, !Task.isCancelled else { return }
                desktop = granted
                authorization = granted ? .allowed : .denied
                UserDefaults.standard.set(granted, forKey: Self.desktopKey)
                if !granted { report("Enable Square Mail in System Settings → Notifications.") }
            } catch is CancellationError {} catch { report(error.localizedDescription) }
        }
    }
    private func content(_ title: String, detail: String, info: [String: String]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        content.userInfo = info
        return content
    }
    private func submit(_ notice: AppNotice) async throws {
        let value = content(notice.title, detail: notice.detail, info: ["account": notice.account, "target": notice.target, "calendar": notice.calendar ?? "", "kind": notice.kind.rawValue, "id": notice.id])
        try await center.add(UNNotificationRequest(identifier: "squaremail.notice." + notice.id, content: value, trigger: nil))
    }
    private func schedule(_ plans: [NoticePlan]) async throws {
        let requests = await center.pendingNotificationRequests()
        let desired = Dictionary(plans.map { ("squaremail.reminder." + $0.id, $0.due) }, uniquingKeysWith: { first, _ in first })
        let stale = requests.filter { $0.identifier.hasPrefix("squaremail.reminder.") && desired[$0.identifier] == nil }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        let existing = Set(requests.map(\.identifier))
        for plan in plans.prefix(32) {
            let id = "squaremail.reminder." + plan.id
            guard !existing.contains(id) || planned[id] != plan.due else { continue }
            let delay = TimeInterval(plan.due) - Date().timeIntervalSince1970
            guard delay > 0 else { continue }
            let value = content(plan.title, detail: "Calendar reminder", info: ["account": plan.account, "target": plan.target, "calendar": plan.calendar, "kind": AppNotice.Kind.reminder.rawValue, "id": plan.id])
            try await center.add(UNNotificationRequest(identifier: id, content: value, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)))
        }
        planned = desired
    }
    private func trimDelivered() async {
        let delivered = await center.deliveredNotifications()
        let ours = delivered.filter { $0.request.identifier.hasPrefix("squaremail.") }.sorted { $0.date > $1.date }
        center.removeDeliveredNotifications(withIdentifiers: ours.dropFirst(50).map { $0.request.identifier })
    }
    private func removePlans() async {
        let requests = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix("squaremail.reminder.") }.map(\.identifier))
        planned.removeAll()
    }
    func verifyControls(_ value: NoticeBatch, accounts: [Account]) async throws {
        precondition(WindowPresentation.isBackground)
        preview(value, accounts: accounts)
        await finishPreview()
        try panel?.verifyButtons()
        act(.read, id: nil); await finishPreview()
        guard batch?.items.allSatisfy({ !$0.unread }) == true else { throw MailError(message: "Mark read did not refresh the bell") }
        setPreference(nil, channel: .mail, toggle: .off); await finishPreview()
        guard batch?.settings.allSatisfy({ !$0.mail }) == true else { throw MailError(message: "Bell preference did not update") }
        setPreference(nil, channel: .mail, toggle: .on); await finishPreview()
        enableDesktop()
        guard permissionTask == nil, previewMode else { throw MailError(message: "Offline bell requested OS permission") }
        act(.clear, id: nil); await finishPreview()
        guard batch?.items.isEmpty == true else { throw MailError(message: "Clear did not refresh the bell") }
        stop()
    }
    private func finishPreview() async {
        while actionTask != nil || refreshTask != nil {
            await actionTask?.value
            await refreshTask?.value
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let account = info["account"] as? String, let target = info["target"] as? String, let raw = info["kind"] as? String, let kind = AppNotice.Kind(rawValue: raw) else { return }
        let item = AppNotice(id: info["id"] as? String ?? "", account: account, kind: kind, target: target, calendar: info["calendar"] as? String, title: response.notification.request.content.title, detail: "", occurred: Int64(Date().timeIntervalSince1970), unread: false)
        await MainActor.run { self.onOpen?(item); self.act(.read, id: item.id) }
    }
}
