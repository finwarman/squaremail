import Foundation

public struct PreviewSnippet {
    public let text: String
    public let separators: [NSRange]
}

public enum MessagePreview {
    private static let inputLimit = 8192
    private static let outputLimit = 512

    public static func render(_ source: String) -> PreviewSnippet {
        let compact = TextNormalizer.compact(HeaderText.decode(String(source.prefix(inputLimit))))
        var text = ""; var separators: [NSRange] = []
        var length = 0
        for line in compact.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !words.isEmpty else { continue }
            if !text.isEmpty {
                separators.append(NSRange(location: length + 1, length: 1))
                text += " | "; length += 3
            }
            text += words; length += words.utf16.count
            if text.count >= outputLimit { break }
        }
        text = String(text.prefix(outputLimit))
        let end = text.utf16.count
        return PreviewSnippet(text: text, separators: separators.filter { NSMaxRange($0) <= end })
    }
}
