import XCTest
@testable import ClassicKit

final class ClassicKitTests: XCTestCase {
    func testCommandRelease() async {
        await MainActor.run {
            for style in [ClassicButton.Style.toolbar, .normal, .menu, .title] {
                let button = ClassicButton("Open", style: style)
                button.highlight(true); button.state = .on
                var invoked = false
                button.onPress = {
                    invoked = true
                    XCTAssertFalse(button.isHighlighted)
                    XCTAssertEqual(button.state, .off)
                }
                button.performClick(nil)
                XCTAssertTrue(invoked); XCTAssertFalse(button.isHighlighted); XCTAssertEqual(button.state, .off)
                button.onPress = nil
            }
            let mode = ClassicButton("Calendar", style: .navigation)
            mode.onPress = { mode.state = .on }
            mode.performClick(nil)
            XCTAssertEqual(mode.state, .on); XCTAssertFalse(mode.isHighlighted)
            mode.onPress = nil
        }
    }

    func testMonthRegionsStaySeparate() {
        for height: CGFloat in [18, 24, 35, 44, 61, 74, 95, 160] {
            let cell = NSRect(x: 11, y: 47, width: 100, height: height)
            for count in 0...20 {
                let layout = MonthCellLayout(cell, count: count)
                let events = (0..<layout.eventCount).map(layout.eventRect)
                XCTAssertEqual(layout.eventCount + layout.moreCount, count)
                for (index, rect) in events.enumerated() {
                    XCTAssertTrue(cell.contains(rect))
                    XCTAssertGreaterThanOrEqual(rect.minY, cell.minY + 22)
                    XCTAssertTrue(events.dropFirst(index + 1).allSatisfy { !$0.intersects(rect) })
                    if layout.moreCount > 0 { XCTAssertFalse(layout.moreRect.intersects(rect)) }
                }
                guard layout.moreCount > 0 else { continue }
                XCTAssertTrue(cell.contains(layout.moreRect))
                if layout.morePlacement == .header {
                    XCTAssertLessThanOrEqual(layout.moreRect.maxY, cell.minY + 22)
                    XCTAssertGreaterThanOrEqual(layout.moreRect.minX, cell.minX + 28)
                } else { XCTAssertGreaterThanOrEqual(layout.moreRect.minY, cell.minY + 22) }
            }
        }
    }
    func testSparkleBoundsAndExpiry() {
        var state = SparkleState()
        for index in 0..<10_000 { state.move(to: NSPoint(x: index * 10, y: 20), at: Double(index) / 1000) }
        XCTAssertEqual(state.particles.count, SparkleState.limit)
        state.expire(at: 11)
        XCTAssertTrue(state.particles.isEmpty)
        state.move(to: NSPoint(x: 100_020, y: 20), at: 11.01)
        state.clear(); XCTAssertTrue(state.particles.isEmpty)
    }

    func testTrailReleasesObservers() async {
        await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)); window.contentView = root
            let previous = window.acceptsMouseMovedEvents
            weak var released: ClassicCursorTrail?
            autoreleasepool {
                let trail = ClassicCursorTrail(); released = trail
                trail.attach(to: root); trail.mode = .enabled
                XCTAssertTrue(window.acceptsMouseMovedEvents)
                trail.mode = .disabled
                XCTAssertEqual(window.acceptsMouseMovedEvents, previous)
                trail.mode = .enabled
            }
            XCTAssertNil(released)
            XCTAssertEqual(window.acceptsMouseMovedEvents, previous)
            window.orderOut(nil)
        }
    }

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
                let titleBar = ClassicTitleBar(frame: NSRect(x: 0, y: 0, width: 1000, height: 32))
                let bitmap = titleBar.bitmapImageRepForCachingDisplay(in: titleBar.bounds)!
                titleBar.cacheDisplay(in: titleBar.bounds, to: bitmap)
                let middle = bitmap.colorAt(x: bitmap.pixelsWide * 70 / 100, y: 1)!
                XCTAssertGreaterThanOrEqual(contrast(.white, middle), 4.5)
                XCTAssertNotEqual(ClassicTheme.todaySurface, ClassicTheme.selectedSurface)
            }
        }
    }
    func testCaptionGlitterIsStatic() async {
        await MainActor.run {
            let view = ClassicTitleBar(frame: NSRect(x: 0, y: 0, width: 1000, height: 32))
            view.title = ""
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let star = bitmap.colorAt(x: 146 * bitmap.pixelsWide / 1000, y: bitmap.pixelsHigh * 2 / 32)!
            let beside = bitmap.colorAt(x: 145 * bitmap.pixelsWide / 1000, y: bitmap.pixelsHigh * 2 / 32)!
            XCTAssertGreaterThan(star.usingColorSpace(.sRGB)!.redComponent, beside.usingColorSpace(.sRGB)!.redComponent)
            let first = bitmap.representation(using: .png, properties: [:])
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertEqual(first, bitmap.representation(using: .png, properties: [:]))
            XCTAssertTrue(SharedClassicTokens.captionGlitter.allSatisfy { $0.y + $0.h <= 6 || $0.y >= 25 })
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
