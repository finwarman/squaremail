import Foundation

public struct TextLink: Sendable {
    public let range: NSRange
    public let url: URL
    public let original: String
    public let tooltip: String
}
public struct PlainDocument: Sendable {
    public let text: String
    public let links: [TextLink]
    public func copyText(_ selection: NSRange) -> String {
        let value = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0, selection.location <= value.length else { return "" }
        let range = NSRange(location: selection.location, length: min(selection.length, value.length - selection.location))
        var output = ""; var cursor = range.location
        for link in links where link.range.location >= range.location && NSMaxRange(link.range) <= NSMaxRange(range) {
            output += value.substring(with: NSRange(location: cursor, length: link.range.location - cursor))
            output += link.original; cursor = NSMaxRange(link.range)
        }
        output += value.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        return output
    }
}
public struct MailLinkDraft: Sendable {
    public let to: [String]
    public let cc: [String]
    public let subject: String
    public let body: String
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "mailto", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), url.absoluteString.utf8.count <= 8192 else { return nil }
        let query = parts.queryItems ?? []
        let item: (String) -> String = { name in query.first { $0.name.lowercased() == name }?.value ?? "" }
        let addresses: (String) -> [String] = { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(100).map { $0 } }
        guard !parts.path.contains(where: \.isNewline), !item("to").contains(where: \.isNewline), !item("cc").contains(where: \.isNewline) else { return nil }
        to = addresses(parts.path + (item("to").isEmpty ? "" : "," + item("to")))
        cc = addresses(item("cc")); subject = String(item("subject").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(400)); body = String(item("body").prefix(8192))
    }
}
