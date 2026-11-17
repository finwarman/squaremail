import XCTest
@testable import ClassicKit

final class ClassicKitTests: XCTestCase {
    func testCalendarRanges() async {
        await MainActor.run {
            let calendar = Calendar(identifier: .iso8601)
            let view = ClassicCalendar()
            view.date = calendar.date(from: DateComponents(year: 2024, month: 2, day: 15))!
            XCTAssertEqual(view.visibleDates.count, 42)
            XCTAssertTrue(view.visibleDates.contains { calendar.component(.month, from: $0) == 2 && calendar.component(.day, from: $0) == 29 })
            view.period = .week
            XCTAssertEqual(view.visibleDates.count, 7)
            XCTAssertEqual(calendar.component(.weekday, from: view.visibleDates[0]), 2)
            view.period = .day
            XCTAssertEqual(view.visibleDates.count, 1)
            XCTAssertTrue(calendar.isDate(view.visibleDates[0], inSameDayAs: view.date))
            for index in 0..<50 {
                view.date = calendar.date(byAdding: .day, value: index, to: view.date)!
                view.period = ClassicCalendarPeriod.allCases[index % 3]
            }
            XCTAssertEqual(view.subviews.count, 42)
        }
    }

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
