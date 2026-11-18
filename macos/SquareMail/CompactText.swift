import Foundation

enum CompactText {
    static func render(_ original: String) -> String {
        var result = ""
        result.reserveCapacity(original.utf8.count)
        var blank = false
        original.enumerateSubstrings(in: original.startIndex..<original.endIndex, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = original[range]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { if !result.isEmpty { blank = true }; return }
            if !result.isEmpty { result += blank ? "\n\n" : "\n" }
            // Leading spaces, quote markers, bullet indentation and separators are content.
            result += line; blank = false
        }
        return result
    }
}
