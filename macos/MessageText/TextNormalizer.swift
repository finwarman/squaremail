import Foundation

public enum TextSpacing: String, Sendable { case original, compact }
public enum LinkStyle: String, Sendable { case original, readable }

public enum TextNormalizer {
    private enum LineKind { case prose, structured }
    private static let paddingScalars: Set<UInt32> = [0x00AD, 0x034F, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]
    private static let paddingRunLimit = 12
    private static let gutterLimit = 16

    public static func compact(_ original: String) -> String {
        var result = ""; result.reserveCapacity(original.utf8.count)
        var fence: String?
        original.enumerateSubstrings(in: original.startIndex..<original.endIndex, options: [.byLines]) { value, _, _, _ in
            let line = value ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.hasPrefix("```") ? "```" : (trimmed.hasPrefix("~~~") ? "~~~" : nil)
            if fence != nil || marker != nil {
                if !result.isEmpty { result += "\n" }
                result += line
                if let marker { fence = fence == marker ? nil : (fence ?? marker) }
                return
            }
            let kind: LineKind = structured(trimmed) ? .structured : .prose
            let cleaned = cleanLine(line, kind: kind)
            guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if !result.isEmpty { result += "\n" }
            result += cleaned
        }
        return result
    }
    private static func structured(_ line: String) -> Bool {
        if line.hasPrefix(">") || line.hasPrefix("|") { return true }
        if ["- ", "* ", "+ ", "• ", "◦ ", "‣ ", "o "].contains(where: line.hasPrefix) { return true }
        let prefix = line.prefix(6)
        if prefix.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) != nil { return true }
        return ["let ", "var ", "func ", "def ", "return ", "if ", "for ", "while ", "class ", "SELECT "].contains(where: line.hasPrefix)
    }
    private static func cleanLine(_ line: String, kind: LineKind) -> String {
        var result = ""; result.reserveCapacity(line.utf8.count)
        var run = String.UnicodeScalarView()
        var hasInvisible = false
        func flush() {
            guard !run.isEmpty else { return }
            if hasInvisible && run.count >= paddingRunLimit { if !result.isEmpty { result += " " } }
            else if kind == .prose && result.isEmpty && run.count >= gutterLimit {}
            else if kind == .prose && !result.isEmpty && run.count >= gutterLimit { result += " " }
            else { result.unicodeScalars.append(contentsOf: run) }
            run.removeAll(keepingCapacity: true); hasInvisible = false
        }
        for scalar in line.unicodeScalars {
            let invisible = paddingScalars.contains(scalar.value)
            if scalar.properties.isWhitespace || invisible {
                run.append(scalar); hasInvisible = hasInvisible || invisible
                continue
            }
            flush(); result.unicodeScalars.append(scalar)
        }
        // Preserve short language-shaping sequences, even at the end of a line.
        if hasInvisible && run.count < paddingRunLimit {
            result += String(run).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
