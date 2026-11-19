// A bounded list snapshot anchors actions despite new arrivals and removed neighbours.
struct MailAdvance {
    private let id: String
    private let following: [String]
    private let preceding: [String]
    private let revision: Int
    private let selection: Int

    init?(_ ids: [String], id: String?, revision: Int, selection: Int) {
        guard let id, let index = ids.firstIndex(of: id) else { return nil }
        self.id = id; self.revision = revision; self.selection = selection
        following = Array(ids.dropFirst(index + 1))
        preceding = Array(ids.prefix(index).reversed())
    }
    func isCurrent(revision: Int, selection: Int) -> Bool {
        self.revision == revision && self.selection == selection
    }
    func next(in ids: [String]) -> Int? {
        let positions = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        if let next = following.lazy.compactMap({ positions[$0] }).first { return next }
        guard let previous = preceding.lazy.compactMap({ positions[$0] }).first else { return positions[id] }
        // A full page can reveal its previously unseen next row after deletion.
        if following.isEmpty, positions[id] == nil, ids.indices.contains(previous + 1) { return previous + 1 }
        return previous
    }
}
