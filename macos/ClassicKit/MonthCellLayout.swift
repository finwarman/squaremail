import AppKit

// Keep date, event rows and overflow in separate regions, including short cells.
struct MonthCellLayout {
    enum MorePlacement { case header, below }
    let eventCount: Int
    let moreCount: Int
    let moreRect: NSRect
    let morePlacement: MorePlacement
    private let cell: NSRect
    private static let dateHeight: CGFloat = 22
    private static let eventStride: CGFloat = 17
    private static let overflowHeight: CGFloat = 12

    init(_ cell: NSRect, count: Int) {
        self.cell = cell
        let space = max(0, cell.height - Self.dateHeight - 2)
        let rows = Int(space / Self.eventStride)
        eventCount = count > rows ? max(0, Int((space - Self.overflowHeight) / Self.eventStride)) : count
        moreCount = max(0, count - eventCount)
        morePlacement = space >= Self.overflowHeight ? .below : .header
        moreRect = morePlacement == .below
            ? NSRect(x: cell.minX + 6, y: cell.minY + Self.dateHeight + CGFloat(eventCount) * Self.eventStride, width: max(0, cell.width - 12), height: Self.overflowHeight)
            : NSRect(x: cell.minX + 28, y: cell.minY + 4, width: max(0, cell.width - 34), height: min(12, max(0, cell.height - 6)))
    }
    func eventRect(_ index: Int) -> NSRect {
        NSRect(x: cell.minX + 4, y: cell.minY + Self.dateHeight + CGFloat(index) * Self.eventStride, width: max(0, cell.width - 8), height: 15)
    }
}
