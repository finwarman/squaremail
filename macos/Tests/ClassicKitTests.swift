import XCTest
@testable import ClassicKit

final class ClassicKitTests: XCTestCase {
    func testSurfaceStaysBounded() async {
        await MainActor.run {
            let surface = ClassicSurface()
            let layer = CALayer()
            for index in 0..<1000 {
                surface.update(layer, bounds: NSRect(x: 0, y: 0, width: index % 200, height: index % 300),
                               fill: ClassicTheme.face, edge: index % 2 == 0 ? .raised : .sunken)
            }
            XCTAssertEqual(layer.sublayers?.count, 8)
            XCTAssertNil(layer.contents)
            XCTAssertTrue(layer.sublayers!.allSatisfy { $0.bounds.width >= 0 && $0.bounds.height >= 0 })
        }
    }

    func testNativeButtonAction() async {
        await MainActor.run {
            _ = NSApplication.shared
            let button = ClassicButton("Open")
            var invoked = false
            button.onPress = { invoked = true }
            button.performClick(nil)
            XCTAssertTrue(invoked)
        }
    }

    func testSelectedTextStaysReadable() async {
        await MainActor.run {
            let row = ClassicRow()
            let cell = ClassicTableCell()
            cell.configure("Mail subject")
            row.addSubview(cell)
            row.isSelected = true
            XCTAssertEqual(cell.textField?.textColor, .white)
            row.isSelected = false
            XCTAssertEqual(cell.textField?.textColor, ClassicTheme.ink)
        }
    }
}
