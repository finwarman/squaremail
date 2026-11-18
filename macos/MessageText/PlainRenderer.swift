import Foundation

public actor PlainRenderer {
    public static let shared = PlainRenderer()
    private var detector: NSDataDetector?
    private static let linkLimit = 128
    private static let urlLimit = 8192
    private static let labelLimit = 72

    public func render(_ original: String, spacing: TextSpacing, links: LinkStyle) throws -> PlainDocument {
        try Task.checkCancellation()
        let source = spacing == .compact ? TextNormalizer.compact(original) : original
        guard links == .readable, source.contains("://") || source.contains("@") || source.contains("www.") else { return PlainDocument(text: source, links: []) }
        if detector == nil { detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) }
        let value = source as NSString
        var found: [(NSRange, URL, String)] = []
        let protected = codeRanges(source)
        detector?.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: value.length)) { match, _, stop in
            if Task.isCancelled || found.count >= Self.linkLimit { stop.pointee = true; return }
            guard let match, let target = match.url, Self.permits(target), !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            guard match.range.length <= Self.urlLimit else { return }
            let (range, url) = wrapped(value, match: match.range, url: target)
            guard range.length <= Self.urlLimit, found.last.map({ NSMaxRange($0.0) <= range.location }) ?? true else { return }
            var (labelRange, label) = label(value, range: range)
            if let previous = found.last, labelRange.location < NSMaxRange(previous.0) {
                labelRange = range; label = ""
            }
            found.append((labelRange, url, label))
        }
        try Task.checkCancellation()
        var output = ""; output.reserveCapacity(source.utf8.count)
        var spans: [TextLink] = []; var cursor = 0; var outputLength = 0
        for (range, url, label) in found {
            let prefix = value.substring(with: NSRange(location: cursor, length: range.location - cursor))
            output += prefix; outputLength += prefix.utf16.count
            let display = displayLabel(label, url: url)
            let start = outputLength; output += display; outputLength += display.utf16.count
            spans.append(TextLink(range: NSRange(location: start, length: display.utf16.count), url: url, original: value.substring(with: range), tooltip: tooltip(url)))
            cursor = NSMaxRange(range)
        }
        output += value.substring(from: cursor)
        return PlainDocument(text: output, links: spans)
    }
    public static func permits(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard ["http", "https", "mailto"].contains(scheme), url.user == nil, url.password == nil, url.absoluteString.utf8.count <= urlLimit else { return false }
        return scheme == "mailto" || url.host?.isEmpty == false
    }
    private func wrapped(_ text: NSString, match: NSRange, url: URL) -> (NSRange, URL) {
        guard match.location > 0, text.substring(with: NSRange(location: match.location - 1, length: 1)) == "<" else { return (match, url) }
        let end = text.range(of: ">", range: NSRange(location: NSMaxRange(match), length: min(Self.urlLimit, text.length - NSMaxRange(match))))
        guard end.location != NSNotFound else { return (match, url) }
        let inner = text.substring(with: NSRange(location: match.location, length: end.location - match.location))
        let parts = inner.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= 16, parts.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }), let expanded = URL(string: parts.joined()), Self.permits(expanded), expanded.host == url.host else { return (match, url) }
        return (NSRange(location: match.location - 1, length: end.location - match.location + 2), expanded)
    }
    private func label(_ text: NSString, range: NSRange) -> (NSRange, String) {
        let contextLength = min(220, range.location)
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: range.location - contextLength, length: contextLength))
        if newline.location == NSNotFound && range.location > contextLength { return (range, "") }
        let lineStart = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        let line = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let leading = line.prefix(while: \.isWhitespace)
        let content = String(line.dropFirst(leading.count))
        let start = range.location - content.utf16.count
        let after = NSMaxRange(range) < text.length ? text.substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        if content.hasSuffix("]("), after == ")", let bracket = content.lastIndex(of: "[") {
            let label = String(content[content.index(after: bracket)...].dropLast(2))
            let labelStart = start + content[..<bracket].utf16.count
            return (NSRange(location: labelStart, length: NSMaxRange(range) + 1 - labelStart), label)
        }
        let isAngle = text.substring(with: NSRange(location: range.location, length: 1)) == "<"
        if isAngle, !content.isEmpty, content.count <= Self.labelLimit, !content.contains("<"), !content.contains("://") {
            let candidate = content.trimmingCharacters(in: .whitespaces)
            let clean = candidate.hasPrefix("[") && candidate.hasSuffix("]") ? String(candidate.dropFirst().dropLast()) : candidate
            return (NSRange(location: start, length: NSMaxRange(range) - start), clean)
        }
        return (range, "")
    }
    private func displayLabel(_ label: String, url: URL) -> String {
        if let destination = safeDestination(url) {
            let prefix = label.isEmpty ? "" : clipped(label, limit: Self.labelLimit) + " ↗ · "
            return prefix + shortURL(destination) + " [Safe Links]"
        }
        if !label.isEmpty { return clipped(label, limit: Self.labelLimit) + " ↗" }
        return shortURL(url)
    }
    private func shortURL(_ url: URL) -> String {
        let host = url.host ?? url.path
        if url.absoluteString.count <= Self.labelLimit { return url.scheme == "mailto" ? url.path : url.absoluteString }
        let path = url.path.isEmpty || url.path == "/" ? "" : clipped(url.path, limit: 28)
        return clipped(host, limit: 44) + path + "…"
    }
    private func safeDestination(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "safelinks.protection.outlook.com" || host.hasSuffix(".safelinks.protection.outlook.com"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let destination = URL(string: raw), Self.permits(destination),
              ["https", "http"].contains(destination.scheme?.lowercased()) else { return nil }
        return destination
    }
    private func tooltip(_ url: URL) -> String {
        var result = url.absoluteString
        if let destination = safeDestination(url) {
            result = "Destination: \(destination.absoluteString)\nOutlook protection: \(url.absoluteString)\nDecoded locally. Further redirects are not checked."
        }
        return result
    }
    private func clipped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit / 2)) + "…" + String(value.suffix(limit / 2 - 1))
    }
    private func codeRanges(_ source: String) -> [NSRange] {
        var ranges: [NSRange] = []; var start: Int?; var offset = 0; var marker = ""
        let sourceLength = source.utf16.count
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: [.byLines]) { line, _, enclosing, stop in
            let text = (line ?? "").trimmingCharacters(in: .whitespaces)
            let fence = text.hasPrefix("```") ? "```" : (text.hasPrefix("~~~") ? "~~~" : "")
            let length = source[enclosing].utf16.count
            if start == nil, !fence.isEmpty { start = offset; marker = fence }
            else if let begin = start, fence == marker { ranges.append(NSRange(location: begin, length: offset + length - begin)); start = nil }
            offset += length
            if ranges.count >= Self.linkLimit { ranges.append(NSRange(location: offset, length: sourceLength - offset)); stop = true }
        }
        if let start { ranges.append(NSRange(location: start, length: sourceLength - start)) }
        return ranges
    }
}
