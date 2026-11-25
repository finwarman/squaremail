import AppKit

enum BackupOperation: String { case claim, release, status, invitation, create, connect, unlock, enable, recovery, lock, disconnect, sync, history, restore }
private struct BackupClaim: Decodable { let acquired: Bool }
enum BackupPhase: String, Decodable { case checking, unavailable, disabled, setup, recovery, locked, ready, busy }
struct BackupStatus: Decodable {
    let phase: BackupPhase
    let unlocked: Bool
    let account: String?
    let completed: Int
    let more: Bool
    let message: String
    static let checking = BackupStatus(phase: .checking, unlocked: false, account: nil, completed: 0, more: false, message: "Checking encrypted backup. Complete any macOS Keychain prompt to continue.")
    static let disabled = BackupStatus(phase: .disabled, unlocked: false, account: nil, completed: 0, more: false, message: "Backup is off. Notes save on this Mac.")
}
struct BackupCreated: Decodable { let status: BackupStatus; let accountKey: String; enum CodingKeys: String, CodingKey { case status; case accountKey = "account_key" } }
struct BackupInvitation: Decodable { let code: String? }
struct BackupRecovery: Decodable { let accountKey: String; enum CodingKeys: String, CodingKey { case accountKey = "account_key" } }
struct BackupVersion: Decodable { let revision: String; let created: Int64 }
struct BackupHistory: Decodable { let items: [BackupVersion] }

@MainActor
final class NotesBackupService {
    private let core: MailCore
    private(set) var status = BackupStatus.checking
    private(set) var message = BackupStatus.checking.message
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var generation = 0
    private var started = false
    private var online = true
    private var awake = true
    private var wake = false
    private var panel: NotesBackupPanel?
    var onRestored: ((NoteDocument) -> Void)?
    init(core: MailCore) { self.core = core }
    func start() {
        guard !started else { return }; started = true
        Task { [weak self] in await self?.refresh() }
    }
    func stop() {
        started = false; cancelWorker(); panel?.close(); panel = nil
        let core = core
        Task { let _: EmptyReply? = try? await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.release.rawValue], mode: .live, queue: .notesBackup) }
    }
    func setOnline(_ value: Bool) {
        online = value
        if !value { cancelWorker(); publish("Offline. Encrypted backup resumes when connected."); return }
        if started { Task { [weak self] in await self?.refresh() } }
    }
    func setAwake(_ value: Bool) {
        awake = value
        if !value { cancelWorker(); return }
        if started { Task { [weak self] in await self?.refresh() } }
    }
    func show(note: String? = nil) {
        if let panel { panel.show(note: note); return }
        let view = NotesBackupPanel(service: self)
        view.onClosed = { [weak self] in
            guard let self else { return }; panel = nil
            if started { Task { [weak self] in await self?.refresh() } }
        }
        panel = view; view.show(note: note)
        Task { [weak self] in await self?.refresh() }
    }
    func requestSync() {
        if status.phase == .unavailable {
            status = .checking; publish(status.message)
            Task { [weak self] in await self?.refresh() }; return
        }
        wake = true; sleeper?.cancel(); resume()
    }
    private func cancelWorker() { generation += 1; worker?.cancel(); sleeper?.cancel(); worker = nil; sleeper = nil }
    private func publish(_ text: String) { message = text; panel?.refresh() }
    func refresh() async {
        let revision = generation
        do { let value: BackupStatus = try await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.status.rawValue], mode: .live, queue: .notesBackup); guard revision == generation else { return }; accept(value) }
        catch {
            guard revision == generation else { return }
            if status.phase == .checking {
                status = BackupStatus(phase: .unavailable, unlocked: false, account: nil, completed: 0, more: false, message: error.localizedDescription)
            }
            publish(error.localizedDescription)
        }
    }
    private func prepare(_ operation: BackupOperation, fields: [String: Any]) async -> [String: Any] {
        let previous = worker; cancelWorker(); await previous?.value
        var payload = fields; payload["command"] = CoreCommand.notesBackup.rawValue; payload["operation"] = operation.rawValue
        return payload
    }
    func invitation() async throws -> BackupInvitation {
        return try await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.invitation.rawValue], mode: .live, queue: .notesBackup)
    }
    func change(_ operation: BackupOperation, fields: [String: Any] = [:]) async throws -> BackupStatus {
        let payload = await prepare(operation, fields: fields)
        return try await core.request(payload, mode: .live, queue: .notesBackup)
    }
    func create(fields: [String: Any]) async throws -> BackupCreated {
        let payload = await prepare(.create, fields: fields)
        return try await core.request(payload, mode: .live, queue: .notesBackup)
    }
    func recovery() async throws -> BackupRecovery {
        let payload = await prepare(.recovery, fields: [:])
        return try await core.request(payload, mode: .live, queue: .notesBackup)
    }
    func history(_ id: String) async throws -> BackupHistory {
        let payload = await prepare(.history, fields: ["id": id])
        return try await core.request(payload, mode: .live, queue: .notesBackup)
    }
    func restore(_ id: String, revision: String) async throws -> NoteDocument {
        let payload = await prepare(.restore, fields: ["id": id, "revision": revision])
        return try await core.request(payload, mode: .live, queue: .notesBackup)
    }
    func accept(_ value: BackupStatus) {
        status = value
        if value.phase != .ready && value.phase != .busy { cancelWorker() }
        publish(value.message); resume()
    }
    private func resume() {
        guard started, online, awake, (status.phase == .ready || status.phase == .busy), worker == nil else { return }
        let revision = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, started, online, awake, revision == generation, (status.phase == .ready || status.phase == .busy) {
                wake = false
                var delay = 30
                do {
                    let claim: BackupClaim = try await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.claim.rawValue], mode: .live, queue: .notesBackup)
                    guard !Task.isCancelled, revision == generation else { return }
                    if claim.acquired {
                        let current: BackupStatus = try await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.status.rawValue], mode: .live, queue: .notesBackup)
                        guard !Task.isCancelled, revision == generation else { return }
                        status = current
                        if current.phase != .ready && current.phase != .busy {
                            publish(current.message)
                            let _: EmptyReply? = try? await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.release.rawValue], mode: .live, queue: .notesBackup)
                            if revision == generation { worker = nil }; return
                        }
                        publish("Syncing encrypted notes…")
                        let value: BackupStatus = try await core.request(["command": CoreCommand.notesBackup.rawValue, "operation": BackupOperation.sync.rawValue], mode: .live, queue: .notesBackup)
                        guard !Task.isCancelled, revision == generation else { return }
                        status = value; publish(value.message); delay = value.more ? 1 : 30
                    } else { publish("Encrypted Notes sync is running in the other Square app. Local edits remain available offline.") }
                } catch {
                    guard !Task.isCancelled, revision == generation else { return }
                    publish(error.localizedDescription + " · retries in a minute"); delay = 60
                }
                if wake { continue }
                let interval = delay
                let wait = Task<Void, Never> { do { try await Task.sleep(for: .seconds(interval)) } catch {} }; sleeper = wait
                await wait.value; sleeper = nil
            }
            if revision == generation { worker = nil }
        }
    }
    func restored(_ note: NoteDocument) { onRestored?(note); requestSync() }
}
