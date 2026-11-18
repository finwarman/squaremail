import MessageText

enum CompactText {
    static func render(_ original: String) -> String { TextNormalizer.compact(original) }
}
