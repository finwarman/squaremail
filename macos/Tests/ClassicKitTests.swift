import XCTest
@testable import ClassicKit

final class ClassicKitTests: XCTestCase {
    func testReaderSegmentStates() async {
        await MainActor.run {
            let button = ClassicButton("Text", icon: .text, style: .segment)
            button.toolTip = "Plain text. Click to switch."
            button.onPress = { button.state = .on }
            button.performClick(nil)
            XCTAssertEqual(button.state, .on)
            XCTAssertEqual(button.title, "Text")
            XCTAssertEqual(button.accessibilityHelp(), button.toolTip)
            XCTAssertFalse(button.isHighlighted)
        }
    }
    func testThemeContrast() async {
        await MainActor.run {
            let saved = ClassicTheme.appearance
            defer { ClassicTheme.configure(saved) }
            for appearance in ClassicTheme.Appearance.allCases {
                ClassicTheme.configure(appearance)
                XCTAssertGreaterThanOrEqual(contrast(ClassicTheme.ink, ClassicTheme.face), 7)
                XCTAssertGreaterThanOrEqual(contrast(.white, ClassicTheme.selection), 4.5)
                XCTAssertGreaterThanOrEqual(contrast(ClassicTheme.muted, ClassicTheme.face), 4.5)
                XCTAssertNotEqual(ClassicTheme.todaySurface, ClassicTheme.selectedSurface)
            }
        }
    }
    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let color = color.usingColorSpace(.sRGB)!
            let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { value -> Double in
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(first); let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testActionOverflow() async {
        await MainActor.run {
            _ = NSApplication.shared
            let bar = ClassicActionBar()
            let primary = ClassicButton("Reply")
            let secondary = ClassicButton("Mark read")
            var clicks = 0
            secondary.onPress = { clicks += 1 }
            bar.addItem(primary, width: 100)
            bar.addItem(secondary, width: 110, priority: .secondary)
            for width: CGFloat in [180, 400, 180] {
                bar.frame = NSRect(x: 0, y: 0, width: width, height: bar.fittingHeight(width)); bar.layout()
                let visible = bar.subviews.filter { !$0.isHidden }
                XCTAssertTrue(visible.allSatisfy { bar.bounds.contains($0.frame) })
                for (index, view) in visible.enumerated() {
                    XCTAssertTrue(visible.dropFirst(index + 1).allSatisfy { !view.frame.intersects($0.frame) })
                }
                XCTAssertEqual(secondary.isHidden, width < 220)
            }
            secondary.title = "Mark unread"; secondary.isEnabled = false
            let disabled = bar.overflowMenu().items.first!
            XCTAssertEqual(disabled.title, "Mark unread"); XCTAssertFalse(disabled.isEnabled)
            secondary.isEnabled = true
            let item = bar.overflowMenu().items.first!
            XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
            XCTAssertEqual(clicks, 1)
        }
    }

    func testProgressBounds() async {
        await MainActor.run {
            let progress = ClassicProgress(frame: NSRect(x: 0, y: 0, width: 130, height: 16))
            progress.state = .determinate(completed: 20, total: 10)
            XCTAssertEqual(progress.accessibilityValue() as? String, "10 of 10")
            progress.state = .determinate(completed: -1, total: 10)
            XCTAssertEqual(progress.accessibilityValue() as? String, "0 of 10")
            progress.state = .indeterminate
            XCTAssertEqual(progress.accessibilityValue() as? String, "Working")
            progress.state = .idle
            XCTAssertEqual(progress.accessibilityValue() as? String, "Idle")
        }
    }

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
            button.onPress = { button.isEnabled = false }
            button.highlight(true); button.performClick(nil)
            XCTAssertFalse(button.isHighlighted)
            XCTAssertEqual(button.state, .off)
            let toggle = ClassicButton("Format", style: .toggle)
            toggle.performClick(nil); XCTAssertEqual(toggle.state, .on)
            toggle.performClick(nil); XCTAssertEqual(toggle.state, .off)
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
