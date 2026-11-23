import XCTest
@testable import ClassicKit

final class ClassicTabsTests: XCTestCase {
    func testSelectionAndBounds() async {
        await MainActor.run {
            _ = NSApplication.shared
            let bar = ClassicTabs(frame: NSRect(x: 0, y: 0, width: 700, height: 30))
            let first = ClassicButton("First", style: .tab); let second = ClassicButton("Second", style: .tab)
            let popout = ClassicButton("Open in window")
            for button in [first, second] { bar.addTab(button, width: 110) }
            bar.setAccessory(popout, width: 150)
            first.state = .on
            bar.layoutSubtreeIfNeeded()
            var invoked = false
            second.onPress = { invoked = true; first.state = .off; second.state = .on; bar.needsLayout = true }
            second.highlight(true); second.performClick(nil); bar.layoutSubtreeIfNeeded()
            XCTAssertTrue(invoked)
            XCTAssertFalse(second.isHighlighted); XCTAssertEqual(second.state, .on); XCTAssertEqual(first.state, .off)
            XCTAssertLessThan(second.frame.minY, first.frame.minY)
            for width: CGFloat in [700, 500, 300, 180] {
                bar.setFrameSize(NSSize(width: width, height: 30)); bar.layoutSubtreeIfNeeded()
                let visible = bar.subviews.filter { !$0.isHidden }
                XCTAssertTrue(visible.allSatisfy { bar.bounds.contains($0.frame) })
                for (index, view) in visible.enumerated() { XCTAssertTrue(visible.dropFirst(index + 1).allSatisfy { !view.frame.intersects($0.frame) }) }
            }
            second.onPress = nil
        }
    }
}
