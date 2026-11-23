import Foundation
import CoreServices

struct NoteSummary: Decodable { let id: String; let title: String; let modified: UInt64; let available: Bool }
struct NoteDocument: Decodable { let id: String; var text: String; let revision: String }
struct NoteList: Decodable { let directory: String; let notes: [NoteSummary]; let pending: Int }

struct NotesMatches: Decodable { let notes: [NoteSummary]; let pending: Int; let total: Int }
struct NotesIndexState: Decodable { let pending: Int; let indexed: Int; let skipped: Int }

@MainActor
final class NotesService {
    private let core: MailCore
    private lazy var watcher = NotesWatcher { [weak self] in self?.onChange?() }
    private var indexTask: Task<Void, Never>?
    private var running = false
    private var generation = 0
    var onChange: (() -> Void)?
    var onIndexed: ((NotesIndexState) -> Void)?
    var onIndexError: ((String) -> Void)?
    init(core: MailCore) { self.core = core }
    func list() async throws -> NoteList {
        let value: NoteList = try await core.request(["command": CoreCommand.notes.rawValue], mode: .live, queue: .notes)
        if running { watcher.watch(URL(fileURLWithPath: value.directory)); if value.pending > 0 { index() } }; return value
    }
    func search(_ query: String) async throws -> NotesMatches { try await core.request(["command": CoreCommand.searchNotes.rawValue, "query": query], mode: .live, queue: .notes) }
    func open(_ id: String) async throws -> NoteDocument { try await core.request(["command": CoreCommand.openNote.rawValue, "id": id], mode: .live, queue: .notes) }
    func create(day: String? = nil) async throws -> NoteDocument { try await core.request(["command": CoreCommand.newNote.rawValue, "day": day as Any? ?? NSNull()], mode: .live, queue: .notes) }
    func save(_ note: NoteDocument) async throws -> NoteDocument { try await core.request(["command": CoreCommand.saveNote.rawValue, "id": note.id, "text": note.text, "revision": note.revision], mode: .live, queue: .notes) }
    func start() { running = true; watcher.start() }
    func stop() { running = false; generation += 1; indexTask?.cancel(); indexTask = nil; watcher.stop() }
    private func index() {
        guard running, indexTask == nil else { return }; let revision = generation
        indexTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == generation { indexTask = nil } }
            do {
                while !Task.isCancelled, running, revision == generation {
                    let state: NotesIndexState = try await core.request(["command": CoreCommand.indexNotes.rawValue], mode: .live, queue: .notes)
                    guard !Task.isCancelled, revision == generation else { return }; onIndexed?(state)
                    if state.pending == 0 { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
            } catch { if !Task.isCancelled, revision == generation { onIndexError?(error.localizedDescription) } }
        }
    }
}

// One recursive OS event stream observes in-place edits as well as atomic replacements.
private final class NotesWatcher: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.finwarman.squaremail.notes-watch", qos: .utility)
    private var stream: FSEventStreamRef?
    private var path: String?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    init(onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
    func watch(_ root: URL) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }; let root = root.resolvingSymlinksInPath()
            guard path != root.path else { return }; clearStream()
            let sink = NotesEventSink { [weak self] in self?.queue.async { [weak self] in self?.changed() } }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: { value in
                guard let value else { return nil }; return UnsafeRawPointer(Unmanaged<NotesEventSink>.fromOpaque(value).retain().toOpaque())
            }, release: { value in if let value { Unmanaged<NotesEventSink>.fromOpaque(value).release() } }, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, _, _, _ in
                guard let info else { return }; Unmanaged<NotesEventSink>.fromOpaque(info).takeUnretainedValue().event()
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return }
            stream = created; path = root.path
        }
    }
    private func clearStream() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil; path = nil
    }
    private func changed() {
        guard !stopped else { return }; timer?.cancel()
        let value = DispatchSource.makeTimerSource(queue: queue)
        timer = value; value.schedule(deadline: .now() + .milliseconds(150))
        value.setEventHandler { [weak self] in
            guard let self, !stopped else { return }; timer?.cancel(); timer = nil
            let callback = onChange; Task { @MainActor in callback() }
        }
        value.resume()
    }
    func start() { queue.async { [weak self] in self?.stopped = false } }
    func stop() { queue.async { [weak self] in guard let self else { return }; stopped = true; timer?.cancel(); timer = nil; clearStream() } }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; timer?.cancel() }
}
private final class NotesEventSink: @unchecked Sendable {
    let event: @Sendable () -> Void
    init(_ event: @escaping @Sendable () -> Void) { self.event = event }
}
