import Foundation
import WebKit

@MainActor
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "squaremail-image"
    private let worker = DispatchQueue(label: "com.finwarman.squaremail.image-resource", qos: .utility, autoreleaseFrequency: .workItem)
    private var resources: [String: URL] = [:]
    private var token = UUID().uuidString.lowercased()
    private var pending: [ObjectIdentifier: WKURLSchemeTask] = [:]
    private(set) var delivered = 0

    func replace(_ resources: [String: URL]) -> String {
        self.resources = resources
        token = UUID().uuidString.lowercased()
        pending.removeAll()
        delivered = 0
        return "\(Self.scheme)://\(token)/"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url, url.scheme == Self.scheme,
              url.host == token, url.query == nil, url.fragment == nil,
              let file = resources[String(url.path.dropFirst())] else {
            urlSchemeTask.didFailWithError(MailError(message: "Image is blocked"))
            return
        }
        pending[key] = urlSchemeTask
        worker.async { [weak self] in
            let result = Result { () throws -> Data in
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 5 * 1024 * 1024 else { throw MailError(message: "Cached image exceeded its limit") }
                return try Data(contentsOf: file, options: .mappedIfSafe)
            }
            DispatchQueue.main.async {
                guard let self, let task = self.pending.removeValue(forKey: key) else { return }
                switch result {
                case .success(let data):
                    task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                    task.didReceive(data)
                    task.didFinish()
                    self.delivered += 1
                case .failure(let error): task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }
}
