import AppKit
import ClassicKit

@MainActor
final class MessageMedia {
    private let core: MailCore
    private weak var reader: ReaderView?
    private var task: Task<Void, Never>?
    private var generation = 0
    private let document = DocumentPreview()

    init(core: MailCore, reader: ReaderView) { self.core = core; self.reader = reader }
    func cancel() { generation += 1; task?.cancel(); task = nil; document.close(); reader?.mediaProgress(.idle) }
    func finish() async { await task?.value }

    func loadImages(_ mail: Mail, mode: MailboxMode) {
        cancel()
        let revision = generation
        reader?.mediaStatus("Loading images. Remote servers may record this request.")
        reader?.mediaProgress(.indeterminate)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == revision { reader?.mediaProgress(.idle) } }
            do {
                let manifest = try await discover(mail, mode: mode)
                guard generation == revision else { return }
                if !manifest.imageIDs.isEmpty { reader?.mediaProgress(.determinate(completed: 0, total: manifest.imageIDs.count)) }
                var files: [String: URL] = [:]
                var failures = 0
                for (index, id) in manifest.imageIDs.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let file: MediaFile = try await core.request(["command": CoreCommand.mediaFile.rawValue, "id": mail.id, "asset": id, "preview": PreviewSize.reader.rawValue], mode: mode, queue: .media)
                        files[id] = try await core.mediaPreview(file, size: .reader)
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures += 1 }
                    guard generation == revision else { return }
                    reader?.mediaStatus("Loaded \(files.count) of \(manifest.imageIDs.count) images…")
                    reader?.mediaProgress(.determinate(completed: index + 1, total: manifest.imageIDs.count))
                }
                try Task.checkCancellation()
                guard generation == revision else { return }
                guard !files.isEmpty else {
                    reader?.mediaStatus(manifest.imageIDs.isEmpty ? "No supported images in this message." : "Images unavailable or blocked by download limits.")
                    return
                }
                reader?.showImages(manifest.html, files: files)
                reader?.mediaStatus((files.count == 1 ? "1 image loaded" : "\(files.count) images loaded") + (failures > 0 ? " · \(failures) unavailable or blocked" : ""))
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                reader?.mediaStatus(error.localizedDescription)
            }
        }
    }

    func attachments(_ mail: Mail, mode: MailboxMode) {
        cancel()
        let revision = generation
        reader?.mediaStatus("Discovering attachments…")
        reader?.mediaProgress(.indeterminate)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == revision { reader?.mediaProgress(.idle) } }
            do {
                let manifest = try await discover(mail, mode: mode)
                try Task.checkCancellation()
                guard generation == revision else { return }
                reader?.showAttachments(manifest.assets)
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                reader?.mediaStatus(error.localizedDescription)
            }
        }
    }

    func preview(_ asset: MediaAsset, mail: Mail, mode: MailboxMode) {
        cancel()
        let revision = generation
        reader?.mediaStatus("Downloading preview…")
        reader?.mediaProgress(.indeterminate)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == revision { reader?.mediaProgress(.idle) } }
            do {
                let file: MediaFile = try await core.request(["command": CoreCommand.mediaFile.rawValue, "id": mail.id, "asset": asset.id, "preview": PreviewSize.thumbnail.rawValue], mode: mode, queue: .media)
                let image = try await core.mediaThumbnail(file)
                try Task.checkCancellation()
                guard generation == revision else { return }
                reader?.showPreview(NSImage(cgImage: image, size: .zero), asset: asset)
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                reader?.mediaStatus(error.localizedDescription)
            }
        }
    }

    private func discover(_ mail: Mail, mode: MailboxMode) async throws -> MediaManifest {
        let cached: MediaReply = try await core.request(["command": CoreCommand.media.rawValue, "id": mail.id, "mode": BodyFetch.cached.rawValue], mode: mode)
        if let value = cached.manifest { return value }
        let reply: MediaReply = try await core.request(["command": CoreCommand.media.rawValue, "id": mail.id, "mode": BodyFetch.fetch.rawValue], mode: mode, queue: .media)
        guard let value = reply.manifest else { throw MailError(message: "Message media is unavailable") }
        return value
    }

    func open(_ asset: MediaAsset, mail: Mail, mode: MailboxMode) {
        cancel()
        let revision = generation
        reader?.mediaStatus("Preparing native preview…")
        reader?.mediaProgress(.indeterminate)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == revision { reader?.mediaProgress(.idle) } }
            do {
                let file: MediaFile = try await core.request(["command": CoreCommand.mediaFile.rawValue, "id": mail.id, "asset": asset.id, "preview": PreviewSize.document.rawValue], mode: mode, queue: .media)
                try Task.checkCancellation()
                guard generation == revision else { return }
                try document.show(file, name: asset.name)
                reader?.mediaStatus("Native preview · \(asset.name)")
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                reader?.mediaStatus(error.localizedDescription)
            }
        }
    }
}
