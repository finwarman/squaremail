import Foundation

// Read bounded image alt attributes as text. This creates no document or network request.
enum ImageLabels {
    private static let htmlLimit = 1024 * 1024
    private static let tagLimit = 4096
    private static let imageLimit = 128
    static func clean(_ text: String, html: String?) -> String {
        guard let html, html.utf8.count <= htmlLimit else { return text }
        let labels = alternatives(html)
        guard !labels.isEmpty else { return text }
        var result: [String] = []
        var fence: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { line, _, _, _ in
            let value = line ?? ""; let trimmed = value.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if fence != nil || marker != nil {
                result.append(value)
                if let marker { fence = fence == marker ? nil : (fence ?? marker) }; return
            }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), labels.contains(String(trimmed.dropFirst().dropLast())) { result.append(String(trimmed.dropFirst().dropLast())) }
            else { result.append(value) }
        }
        return result.joined(separator: "\n")
    }
    private static func alternatives(_ html: String) -> Set<String> {
        let value = html as NSString; var cursor = 0; var labels: Set<String> = []; var count = 0; var scanned = 0
        while cursor < value.length, count < imageLimit, scanned < 1024 {
            scanned += 1
            let start = value.range(of: "<", range: NSRange(location: cursor, length: value.length - cursor))
            guard start.location != NSNotFound else { break }
            if value.substring(with: NSRange(location: start.location, length: min(4, value.length - start.location))) == "<!--" {
                let end = value.range(of: "-->", range: NSRange(location: start.location, length: value.length - start.location))
                guard end.location != NSNotFound else { break }; cursor = NSMaxRange(end); continue
            }
            let length = min(tagLimit, value.length - start.location)
            let fragment = value.substring(with: NSRange(location: start.location, length: length))
            guard let end = tagEnd(fragment) else { cursor = start.location + length; continue }
            let tag = String(fragment[..<end]); cursor = start.location + fragment[..<end].utf16.count + 1
            guard tag.lowercased().hasPrefix("<img"), tag.dropFirst(4).first.map({ $0.isWhitespace || $0 == "/" }) == true else { continue }
            count += 1
            if let alt = attribute(tag, name: "alt"), alt.utf8.count <= 512 { let decoded = HeaderText.decode(alt); if !decoded.isEmpty { labels.insert(decoded) } }
        }
        return labels
    }
    private static func tagEnd(_ value: String) -> String.Index? {
        var quote: Character?
        for index in value.indices {
            let char = value[index]
            if let active = quote { if char == active { quote = nil }; continue }
            if char == "\"" || char == "'" { quote = char }
            else if char == ">" { return index }
        }
        return nil
    }
    private static func attribute(_ tag: String, name: String) -> String? {
        var index = tag.index(tag.startIndex, offsetBy: 4)
        while index < tag.endIndex {
            while index < tag.endIndex, tag[index].isWhitespace || tag[index] == "/" { index = tag.index(after: index) }
            let start = index
            while index < tag.endIndex, tag[index].isLetter || tag[index] == "-" { index = tag.index(after: index) }
            guard start != index else { break }
            let key = String(tag[start..<index]).lowercased()
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex, tag[index] == "=" else { continue }
            index = tag.index(after: index)
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex else { break }
            let quote = tag[index] == "\"" || tag[index] == "'" ? tag[index] : nil
            if quote != nil { index = tag.index(after: index) }
            let begin = index
            while index < tag.endIndex, quote.map({ tag[index] != $0 }) ?? !tag[index].isWhitespace { index = tag.index(after: index) }
            if key == name { return String(tag[begin..<index]) }
            if quote != nil, index < tag.endIndex { index = tag.index(after: index) }
        }
        return nil
    }
}
