import AppKit
import Network

@MainActor
private protocol SyncDriving {
    func refresh() async throws
    func step() async throws -> SyncStep
}

@MainActor
private struct CoreSyncDriver: SyncDriving {
    let core: MailCore
    func refresh() async throws {
        let _: EmptyReply = try await core.request(["command": CoreCommand.syncNow.rawValue], mode: .live)
    }
    func step() async throws -> SyncStep {
        try await core.request(["command": CoreCommand.syncNext.rawValue], mode: .live, queue: .sync)
    }
}

@MainActor
final class SyncCoordinator {
    enum Activity { case running, paused }
    enum Connectivity { case online, offline }
    enum Status { case checking, syncing, waiting, offline, sleeping, paused, failed }
    enum RefreshReason { case automatic, manual }
    private enum Reachability { case system, scripted }
    private let driver: any SyncDriving
    private let reachability: Reachability
    private let pageDelay: Int
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var feedback: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var observations: [NSObjectProtocol] = []
    private var online = true
    private var sleeping = false
    private var enabled = false
    private var refresh = false
    private var generation = 0
    private var monitorRevision = 0
    private var status: Status = .paused
    private var updates = 0
    private var issue: SyncStep?
    var onChange: ((SyncStep) -> Void)?
    var onConnection: ((Connectivity) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onDetail: ((SyncStep, Int) -> Void)?

    convenience init(core: MailCore) { self.init(driver: CoreSyncDriver(core: core), reachability: .system, pageDelay: 300) }
    private init(driver: any SyncDriving, reachability: Reachability, pageDelay: Int) {
        self.driver = driver; self.reachability = reachability; self.pageDelay = pageDelay
        let workspace = NSWorkspace.shared.notificationCenter
        observations.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stopLoop(); self?.publish(.sleeping) }
        })
        observations.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.requestRefresh() }
        })
    }
    private func publish(_ value: Status) {
        guard status != value else { return }
        status = value; onStatus?(value)
    }
    private func stopLoop() {
        generation += 1
        loop?.cancel(); loop = nil
        sleeper?.cancel(); sleeper = nil
        feedback?.cancel(); feedback = nil
    }
    func setActivity(_ activity: Activity) {
        enabled = activity == .running
        guard enabled else {
            stopLoop(); monitorRevision += 1; monitor?.cancel(); monitor = nil; publish(.paused); return
        }
        if monitor == nil && reachability == .system {
            monitorRevision += 1; let revision = monitorRevision
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self, enabled, monitorRevision == revision else { return }
                    let regained = !online && connected
                    online = connected; onConnection?(connected ? .online : .offline)
                    if !connected { stopLoop(); publish(.offline) }
                    if regained { requestRefresh() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.finwarman.squaremail.reachability", qos: .utility)); self.monitor = monitor
        }
        requestRefresh()
    }
    func requestRefresh(_ reason: RefreshReason = .automatic) {
        refresh = true
        if !online { publish(.offline); return }
        if sleeping { publish(.sleeping); return }
        guard enabled else { return }
        if reason == .manual && status != .syncing { updates = 0; issue = nil; publish(.checking) }
        // Wake only the scheduler delay. Do not cancel an in-flight provider request.
        sleeper?.cancel()
        kick()
    }
    func kick() {
        guard enabled, online, !sleeping, loop == nil else { return }
        let revision = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == revision, let delay = await tick() else { return }
                guard generation == revision, !Task.isCancelled else { return }
                let wait = Task { try await Task.sleep(for: .milliseconds(delay)) }
                sleeper = wait
                do { try await wait.value } catch { if Task.isCancelled { return } }
                guard generation == revision else { return }
                sleeper = nil
            }
        }
    }
    private func tick() async -> Int? {
        guard enabled, online, !sleeping else { return nil }
        let revision = generation
        // Fast empty scheduler polls have no visible busy state.
        if status != .syncing && status != .checking {
            feedback = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, generation == revision else { return }
                publish(.checking)
            }
        }
        do {
            if refresh { refresh = false; try await driver.refresh(); try Task.checkCancellation() }
            let reply = try await driver.step()
            try Task.checkCancellation()
            guard generation == revision else { return nil }
            feedback?.cancel(); feedback = nil
            if reply.worked {
                updates += 1
                if reply.error != nil { issue = reply }
                publish(.syncing)
                onChange?(reply); onDetail?(reply, updates)
                if reply.more == false && !refresh {
                    publish(issue == nil ? .waiting : .failed)
                    updates = 0; issue = nil
                    return 5000
                }
                return pageDelay
            }
            if status == .syncing || status == .checking || status == .paused || status == .offline || status == .sleeping {
                if issue != nil { publish(.failed) }
                else { publish(.waiting) }
                updates = 0; issue = nil
            }
            return 5000
        } catch {
            guard !Task.isCancelled, generation == revision, enabled, online, !sleeping else { return nil }
            feedback?.cancel(); feedback = nil
            let failure = SyncStep(worked: false, accountId: nil, kind: nil, error: error.localizedDescription, retryAfter: 15)
            onChange?(failure); onDetail?(failure, updates); publish(.failed)
            return 15000
        }
    }
    deinit {
        loop?.cancel(); sleeper?.cancel(); feedback?.cancel(); monitor?.cancel()
        for observer in observations { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

@MainActor
private final class ScriptedSyncDriver: SyncDriving {
    var replies: [SyncStep]
    var delay: Duration = .zero
    private(set) var calls = 0
    private(set) var refreshes = 0
    init(_ replies: [SyncStep]) { self.replies = replies }
    func refresh() async throws { refreshes += 1 }
    func step() async throws -> SyncStep {
        calls += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        return replies.isEmpty ? SyncStep(worked: false, accountId: nil, kind: nil, error: nil, retryAfter: nil) : replies.removeFirst()
    }
}

extension SyncCoordinator {
    static func verifyFlow() async throws {
        precondition(WindowPresentation.isBackground)
        let page = SyncStep(worked: true, accountId: "fixture", kind: .mail, error: nil, retryAfter: nil, more: true)
        let end = SyncStep(worked: true, accountId: "fixture", kind: .calendar, error: nil, retryAfter: nil, more: false)
        let driver = ScriptedSyncDriver([page, end])
        let worker = SyncCoordinator(driver: driver, reachability: .scripted, pageDelay: 80)
        defer { worker.setActivity(.paused) }
        var states: [Status] = []
        worker.onStatus = { states.append($0) }
        worker.setActivity(.running)
        try await waitUntil { driver.calls >= 1 }
        guard worker.status == .syncing, !states.contains(.waiting) else { throw MailError(message: "Sync ended between pages") }
        try await waitUntil { worker.status == .waiting }
        guard driver.calls == 2, states == [.syncing, .waiting], worker.feedback == nil else { throw MailError(message: "Batch progress flashed or failed to complete") }
        let oldSleep = worker.sleeper
        worker.requestRefresh(.manual)
        guard oldSleep?.isCancelled == true, worker.loop?.isCancelled == false else { throw MailError(message: "Manual refresh did not wake only the idle delay") }
        try await waitUntil { driver.calls >= 3 }
        guard driver.refreshes == 2, worker.status == .waiting else { throw MailError(message: "Manual refresh waited for the idle poll") }
        driver.replies = [SyncStep(worked: true, accountId: "fixture", kind: .mail, error: "Synthetic retry", retryAfter: 60, more: false)]
        worker.requestRefresh(.manual)
        try await waitUntil { worker.status == .failed }
        worker.setActivity(.paused)
        guard worker.loop == nil, worker.sleeper == nil, worker.feedback == nil else { throw MailError(message: "Paused sync retained workers") }
        let slow = ScriptedSyncDriver([]); slow.delay = .milliseconds(100)
        let replacement = SyncCoordinator(driver: slow, reachability: .scripted, pageDelay: 1)
        defer { replacement.setActivity(.paused) }
        replacement.setActivity(.running)
        try await waitUntil { slow.calls == 1 }
        replacement.setActivity(.paused); slow.delay = .zero; replacement.setActivity(.running)
        try await waitUntil { replacement.status == .waiting }
        guard replacement.loop?.isCancelled == false else { throw MailError(message: "A cancelled sync stopped its replacement") }
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now >= end { throw MailError(message: "Synthetic sync scheduler timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
