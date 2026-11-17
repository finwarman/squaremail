import Foundation
import MailBridge

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
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    private let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func request<T: Decodable>(_ command: [String: Any], mode: MailboxMode,
                               queue: WorkQueue = .local) async throws -> T {
        let file = directory.appendingPathComponent(mode == .demo ? "demo.sqlite" : "mail.sqlite")
        var payload = command
        payload["database"] = file.path
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { continuation in
            let work: @Sendable () -> Void = {
                precondition(!Thread.isMainThread, "Mail I/O must stay off the AppKit thread")
                do {
                    if !FileManager.default.fileExists(atPath: file.path) {
                        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    let response = String(decoding: data, as: UTF8.self).withCString { squaremail_call($0) }
                    guard let response else { throw MailError(message: "The mail core returned no response") }
                    defer { squaremail_free(response) }
                    let bytes = Data(bytes: response, count: strlen(response))
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let reply = try decoder.decode(CoreReply<T>.self, from: bytes)
                    if let error = reply.error { throw MailError(message: error) }
                    guard let result = reply.ok else { throw MailError(message: "The mail core response was invalid") }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
            switch queue {
            case .local: local.async(execute: work)
            case .network: network.addOperation(work)
            }
        }
    }
}
