import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

private final class PreviewTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: QLThumbnailGenerator.Request?
    private var image: CGImage?
    let ready = DispatchSemaphore(value: 0)

    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func begin(_ request: QLThumbnailGenerator.Request) throws {
        lock.lock()
        self.request = request
        let value = cancelled
        lock.unlock()
        if value { QLThumbnailGenerator.shared.cancel(request); throw CancellationError() }
    }
    func finish(_ image: CGImage?) {
        lock.lock()
        if !cancelled { self.image = image }
        request = nil
        lock.unlock()
        ready.signal()
    }
    func result() throws -> CGImage {
        try check()
        lock.lock(); let value = image; image = nil; lock.unlock()
        guard let value else { throw MailError(message: "No thumbnail could be generated") }
        return value
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = request; request = nil; image = nil; lock.unlock()
        if let value { QLThumbnailGenerator.shared.cancel(value) }
        ready.signal()
    }
}

final class MediaRenderer: Sendable {
    private let directory: URL
    private let worker = DispatchQueue(label: "com.finwarman.squaremail.thumbnails", qos: .utility, autoreleaseFrequency: .workItem)
    private static let fileLimit = 8 * 1024 * 1024
    private static let pixelLimit = 40_000_000
    private static let cacheLimit = 128 * 1024 * 1024
    private static let cacheCount = 512

    init(directory: URL) { self.directory = directory.standardizedFileURL }

    func image(_ url: URL) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.width <= PreviewSize.thumbnail.pixels, image.height <= PreviewSize.thumbnail.pixels else {
                    continuation.resume(throwing: MailError(message: "Cached thumbnail is unavailable")); return
                }
                continuation.resume(returning: image)
            }
        }
    }

    func preview(_ file: MediaFile, size: PreviewSize) async throws -> URL {
        let ticket = PreviewTicket()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                worker.async {
                    do { continuation.resume(returning: try self.render(file, size: size, ticket: ticket)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { ticket.cancel() })
    }

    private func render(_ file: MediaFile, size: PreviewSize, ticket: PreviewTicket) throws -> URL {
        precondition(!Thread.isMainThread)
        try ticket.check()
        let source = URL(fileURLWithPath: file.path).standardizedFileURL
        let relative = source.pathComponents.dropFirst(directory.pathComponents.count)
        guard source.path.hasPrefix(directory.path + "/"), relative.count == 3,
              relative.first == "mail.sqlite.media" || relative.first == "demo.sqlite.media",
              source.pathExtension == "bin" else { throw MailError(message: "Invalid media cache path") }
        let output = source.deletingPathExtension().appendingPathExtension("\(size.pixels).png")
        let manager = FileManager.default
        if manager.fileExists(atPath: output.path) {
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
            return output
        }
        let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.fileLimit + 1
        guard bytes <= Self.fileLimit else { throw MailError(message: "Preview exceeds the file limit") }
        let image: CGImage
        if let type = DocumentType(rawValue: file.mime) {
            guard size == .thumbnail else { throw MailError(message: "Documents cannot be embedded as email images") }
            let request = QLThumbnailGenerator.Request(fileAt: source, size: CGSize(width: 160, height: 160), scale: 2, representationTypes: .thumbnail)
            request.contentType = UTType(mimeType: type.rawValue) ?? .data
            try ticket.begin(request)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                ticket.finish(representation?.cgImage)
            }
            guard ticket.ready.wait(timeout: .now() + 10) == .success else {
                ticket.cancel()
                throw MailError(message: "Document thumbnail timed out")
            }
            image = try ticket.result()
        } else {
            guard let source = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= Self.pixelLimit / height,
                  let imageValue = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: size.pixels
                  ] as CFDictionary) else { throw MailError(message: "Unsupported, malformed or oversized image") }
            image = imageValue
        }
        try ticket.check()
        guard image.width <= size.pixels, image.height <= size.pixels else { throw MailError(message: "Thumbnail exceeded its pixel budget") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw MailError(message: "Cannot encode thumbnail") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MailError(message: "Cannot encode thumbnail") }
        try (data as Data).write(to: output, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try trim(source.deletingLastPathComponent().deletingLastPathComponent(), keeping: output)
        return output
    }

    private func trim(_ root: URL, keeping: URL) throws {
        let manager = FileManager.default
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            if values.isRegularFile == true { files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)) }
        }
        var bytes = files.reduce(0) { $0 + $1.1 }
        var count = files.count
        for (url, length, _) in files.sorted(by: { $0.2 < $1.2 }) {
            guard bytes > Self.cacheLimit || count > Self.cacheCount else { break }
            guard url != keeping else { continue }
            do { try manager.removeItem(at: url); bytes -= length; count -= 1 } catch { continue }
        }
    }
}
