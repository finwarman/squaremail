import Foundation
import CoreGraphics
import MailBridge

private final class RequestTicket: @unchecked Sendable {
    let pointer = squaremail_token_new()!
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        squaremail_token_cancel(pointer)
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    deinit { squaremail_token_free(pointer) }
}

private struct CoreReply<Value: Decodable>: Decodable {
    let ok: Value?
    let error: String?
}

final class MailCore {
    private let local = DispatchQueue(label: "com.finwarman.squaremail.cache", qos: .userInitiated,
                                     autoreleaseFrequency: .workItem)
    private let network: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.finwarman.squaremail.providers"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let sync = MailCore.makeQueue("sync", limit: 1)
    private let login = MailCore.makeQueue("login", limit: 1)
    private let media = MailCore.makeQueue("media", limit: 1)
    private let renderer: MediaRenderer
    private let directory: URL

    private static func makeQueue(_ name: String, limit: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.finwarman.squaremail." + name
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = limit
        return queue
    }

    init(directory: URL) throws {
        self.directory = directory
        self.renderer = MediaRenderer(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func request<T: Decodable>(_ command: [String: Any], mode: MailboxMode,
                               queue: WorkQueue = .local) async throws -> T {
        let file = directory.appendingPathComponent(mode == .demo ? "demo.sqlite" : "mail.sqlite")
        var payload = command
        payload["database"] = file.path
        let data = try JSONSerialization.data(withJSONObject: payload)
        let ticket = RequestTicket()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let work: @Sendable () -> Void = {
                    precondition(!Thread.isMainThread, "Mail I/O must stay off the AppKit thread")
                    do {
                        try ticket.check()
                        let response = String(decoding: data, as: UTF8.self).withCString { squaremail_call_cancelable($0, ticket.pointer) }
                        guard let response else { throw MailError(message: "The mail core returned no response") }
                        defer { squaremail_free(response) }
                        try ticket.check()
                        let bytes = Data(bytes: response, count: strlen(response))
                        let decoder = JSONDecoder()
                        let reply = try decoder.decode(CoreReply<T>.self, from: bytes)
                        if let error = reply.error { throw MailError(message: error) }
                        guard let result = reply.ok else { throw MailError(message: "The mail core response was invalid") }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
                switch queue {
                case .local: local.async(execute: work)
                case .network: network.addOperation(work)
                case .sync: sync.addOperation(work)
                case .login: login.addOperation(work)
                case .media: media.addOperation(work)
                }
            }
        }, onCancel: { ticket.cancel() })
    }

    func mediaPreview(_ file: MediaFile, size: PreviewSize) async throws -> URL {
        try await renderer.preview(file, size: size)
    }

    func mediaThumbnail(_ file: MediaFile) async throws -> CGImage {
        let url = try await renderer.preview(file, size: .thumbnail)
        return try await renderer.image(url)
    }
}
