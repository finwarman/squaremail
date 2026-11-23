import Foundation

public actor PlainRenderer {
    public static let shared = PlainRenderer()
    private var detector: NSDataDetector?
    private static let linkLimit = 128
    private static let urlLimit = 8192
    private static let labelLimit = 72

    public func render(_ original: String, spacing: TextSpacing, links: LinkStyle, html: String? = nil) throws -> PlainDocument {
        try Task.checkCancellation()
        let source = spacing == .compact ? TextNormalizer.compact(ImageLabels.clean(original, html: html)) : original
        guard links == .readable, source.contains("://") || source.contains("@") || source.contains("www.") else { return PlainDocument(text: source, links: []) }
        if detector == nil { detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) }
        let value = source as NSString
        var found: [(NSRange, URL, String)] = []
        let protected = codeRanges(source)
        // Parse explicit links before detecting bare URLs, including URLs used as labels.
        let angles = try NSRegularExpression(pattern: #"(?i)\[[^\[\]\r\n]{1,512}\]\(https?://[^\s<>]{1,8192}\)|<https?://[^<>]{1,8192}>"#)
        angles.enumerateMatches(in: source, range: NSRange(location: 0, length: value.length)) { match, _, stop in
            if Task.isCancelled || found.count >= Self.linkLimit { stop.pointee = true; return }
            guard let match, !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            let token = value.substring(with: match.range)
            if token.hasPrefix("["), let split = token.range(of: "](", options: .backwards), let url = URL(string: String(token[split.upperBound...].dropLast())), Self.permits(url) {
                found.append((match.range, url, String(token[token.index(after: token.startIndex)..<split.lowerBound]))); return
            }
            let raw = token.dropFirst().dropLast()
            let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count <= 16, lines.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }), let url = URL(string: lines.joined()), Self.permits(url) else { return }
            let (range, label) = label(value, range: match.range, boundary: found.last.map { NSMaxRange($0.0) } ?? 0)
            found.append((range, url, label))
        }
        let explicit = found.map(\.0)
        var boundary = 0
        detector?.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: value.length)) { match, _, stop in
            if Task.isCancelled || found.count >= Self.linkLimit * 2 { stop.pointee = true; return }
            guard let match, let target = match.url, Self.permits(target), !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }), !explicit.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            guard match.range.length <= Self.urlLimit else { return }
            let (range, url) = wrapped(value, match: match.range, url: target)
            let (labelRange, text) = label(value, range: range, boundary: boundary)
            guard !explicit.contains(where: { NSIntersectionRange($0, labelRange).length > 0 }) else { return }
            found.append((labelRange, url, text)); boundary = NSMaxRange(labelRange)
        }
        found.sort { $0.0.location < $1.0.location }
        found = Array(found.prefix(Self.linkLimit))
        if spacing == .compact {
            var unique: [(NSRange, URL, String)] = []
            for item in found {
                if let previous = unique.last, item.0.location >= NSMaxRange(previous.0), !item.2.isEmpty, previous.1 == item.1, previous.2 == item.2,
                   value.substring(with: NSRange(location: NSMaxRange(previous.0), length: item.0.location - NSMaxRange(previous.0))).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    unique[unique.count - 1] = (NSRange(location: previous.0.location, length: NSMaxRange(item.0) - previous.0.location), item.1, item.2)
                } else { unique.append(item) }
            }
            found = unique
        }
        try Task.checkCancellation()
        var output = ""; output.reserveCapacity(source.utf8.count)
        var spans: [TextLink] = []; var cursor = 0; var outputLength = 0
        for (range, url, label) in found {
            let prefix = value.substring(with: NSRange(location: cursor, length: range.location - cursor))
            output += prefix; outputLength += prefix.utf16.count
            if label.isEmpty || range.location == cursor, let previous = output.last, !previous.isWhitespace, !"([<{/".contains(previous) { output += " "; outputLength += 1 }
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
    private func label(_ text: NSString, range: NSRange, boundary: Int) -> (NSRange, String) {
        let contextLength = min(600, range.location - min(range.location, boundary))
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: range.location - contextLength, length: contextLength))
        if newline.location == NSNotFound && range.location - boundary > contextLength { return (range, "") }
        let lineStart = newline.location == NSNotFound ? boundary : max(boundary, NSMaxRange(newline))
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
        if !isAngle, content.hasSuffix("]"), let bracket = content.lastIndex(of: "[") {
            let label = String(content[content.index(after: bracket)...].dropLast())
            let labelStart = start + content[..<bracket].utf16.count
            return (NSRange(location: labelStart, length: NSMaxRange(range) - labelStart), label)
        }
        if isAngle, !content.isEmpty, content.count <= 512, !content.contains("<") {
            let candidate = content.trimmingCharacters(in: .whitespaces)
            if candidate.contains("://"), !(candidate.hasPrefix("[") && candidate.hasSuffix("]")) { return (range, "") }
            let clean = cleanLabel(candidate)
            return (NSRange(location: start, length: NSMaxRange(range) - start), clean)
        }
        return (range, "")
    }
    private func cleanLabel(_ value: String) -> String {
        if let split = value.range(of: "] [", options: .backwards) {
            let first = String(value[..<split.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let second = String(value[split.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            if first == second { return first }
        }
        if value.hasPrefix("["), value.hasSuffix("]") { return String(value.dropFirst().dropLast()) }
        return value
    }
    private func displayLabel(_ label: String, url: URL) -> String {
        let destination = safeDestination(url) ?? url
        if !label.isEmpty {
            if let claimed = URL(string: label), ["http", "https"].contains(claimed.scheme?.lowercased()), claimed.host != nil { return shortURL(destination) + " ↗" }
            return clipped(label, limit: Self.labelLimit) + " ↗"
        }
        return shortURL(destination)
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
            result = "Destination: \(destination.absoluteString)\nSafe Links protection: \(url.absoluteString)\nDecoded locally. Further redirects are not checked."
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
