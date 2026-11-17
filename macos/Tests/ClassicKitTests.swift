import XCTest
@testable import ClassicKit

final class ClassicKitTests: XCTestCase {
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
