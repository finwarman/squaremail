import Foundation
import Darwin

struct NoteSummary: Decodable { let id: String; let title: String; let modified: UInt64 }
struct NoteDocument: Decodable { let id: String; var text: String; let revision: String }
struct NoteList: Decodable { let directory: String; let notes: [NoteSummary] }

@MainActor
final class NotesService {
    private let core: MailCore
    private lazy var watcher = NotesWatcher { [weak self] in self?.onChange?() }
    var onChange: (() -> Void)?
    init(core: MailCore) { self.core = core }
    func list() async throws -> NoteList {
        let value: NoteList = try await core.request(["command": CoreCommand.notes.rawValue], mode: .live)
        watcher.watch(URL(fileURLWithPath: value.directory)); return value
    }
    func open(_ id: String) async throws -> NoteDocument { try await core.request(["command": CoreCommand.openNote.rawValue, "id": id], mode: .live) }
    func create(day: String? = nil) async throws -> NoteDocument { try await core.request(["command": CoreCommand.newNote.rawValue, "day": day as Any? ?? NSNull()], mode: .live) }
    func save(_ note: NoteDocument) async throws -> NoteDocument { try await core.request(["command": CoreCommand.saveNote.rawValue, "id": note.id, "text": note.text, "revision": note.revision], mode: .live) }
    func start() { watcher.start() }
    func stop() { watcher.stop() }
}

// Directory events are coalesced off the editor path. No polling while idle.
private final class NotesWatcher: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.finwarman.squaremail.notes-watch", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var stopped = false
    init(onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
    func watch(_ root: URL) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            for url in [root, root.appendingPathComponent("Daily")] where sources[url.path] == nil {
                let descriptor = Darwin.open(url.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self, let active = sources[url.path] else { return }
                    if active.data.contains(.delete) || active.data.contains(.rename) { sources.removeValue(forKey: url.path)?.cancel() }
                    changed()
                }
                source.setCancelHandler { Darwin.close(descriptor) }
                sources[url.path] = source; source.resume()
            }
        }
    }
    private func changed() {
        timer?.cancel()
        let value = DispatchSource.makeTimerSource(queue: queue)
        timer = value; value.schedule(deadline: .now() + .milliseconds(200))
        value.setEventHandler { [weak self] in
            guard let self else { return }; timer?.cancel(); timer = nil
            let callback = onChange; Task { @MainActor in callback() }
        }
        value.resume()
    }
    func start() { queue.async { [weak self] in self?.stopped = false } }
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }; stopped = true; timer?.cancel(); timer = nil
            for source in sources.values { source.cancel() }; sources.removeAll()
        }
    }
    deinit { for source in sources.values { source.cancel() }; timer?.cancel() }
}
