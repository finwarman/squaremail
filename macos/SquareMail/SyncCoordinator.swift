import AppKit
import Network

@MainActor
final class SyncCoordinator {
    enum Activity { case running, paused }
    enum Connectivity { case online, offline }
    private let core: MailCore
    private var loop: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var observations: [NSObjectProtocol] = []
    private var online = true
    private var sleeping = false
    private var enabled = false
    private var refresh = false
    var onChange: ((SyncStep) -> Void)?
    var onConnection: ((Connectivity) -> Void)?

    init(core: MailCore) {
        self.core = core
        let workspace = NSWorkspace.shared.notificationCenter
        observations.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.loop?.cancel(); self?.loop = nil }
        })
        observations.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.kick() }
        })
    }

    func setActivity(_ activity: Activity) {
        enabled = activity == .running
        guard enabled else {
            loop?.cancel(); loop = nil
            monitor?.cancel(); monitor = nil
            return
        }
        if monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let regained = !self.online && connected
                    self.online = connected
                    self.onConnection?(connected ? .online : .offline)
                    if !connected { self.loop?.cancel(); self.loop = nil }
                    if regained { self.requestRefresh() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.finwarman.squaremail.reachability", qos: .utility))
            self.monitor = monitor
        }
        requestRefresh()
    }

    func requestRefresh() { refresh = true; kick() }
    func kick() {
        guard enabled, online, !sleeping, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.tick() else { return }
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            }
        }
    }

    private func tick() async -> Int? {
        guard enabled, online, !sleeping else { return nil }
        do {
            if refresh {
                refresh = false
                let _: EmptyReply = try await core.request(["command": CoreCommand.syncNow.rawValue], mode: .live)
            }
            let reply: SyncStep = try await core.request(["command": CoreCommand.syncNext.rawValue], mode: .live, queue: .sync)
            try Task.checkCancellation()
            if reply.worked { onChange?(reply) }
            return reply.worked ? 300 : 5000
        } catch is CancellationError { return nil }
        catch {
            onChange?(SyncStep(worked: false, accountId: nil, kind: nil, error: error.localizedDescription, retryAfter: 15))
            return 15000
        }
    }

    deinit {
        loop?.cancel()
        monitor?.cancel()
        for observer in observations { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
