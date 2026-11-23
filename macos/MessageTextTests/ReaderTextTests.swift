import Foundation
import XCTest
@testable import MessageText

final class ReaderTextTests: XCTestCase {
    func testPreheaderPadding() {
        let padding = String(repeating: "\u{2007}\u{034F}\u{00AD}\u{200C}", count: 128)
        XCTAssertEqual(TextNormalizer.compact("Preview" + padding + "\n\n\nBody"), "Preview\nBody")
        XCTAssertEqual(TextNormalizer.compact("Hello" + padding + "world"), "Hello world")
        XCTAssertEqual(TextNormalizer.compact(String(repeating: " ", count: 80) + "Body"), "Body")
    }

    func testHierarchyAndLanguage() {
        let source = "\nIntro\n\n\n- one\n  - nested\n\n> Reply\n> > Earlier\n------\n\n"
        XCTAssertEqual(TextNormalizer.compact(source), "Intro\n- one\n  - nested\n> Reply\n> > Earlier\n------")
        let language = "می\u{200C}روم 👩\u{200D}💻 a\u{034F}b"
        XCTAssertEqual(TextNormalizer.compact(language), language)
        XCTAssertEqual(TextNormalizer.compact("a\u{034F}"), "a\u{034F}")
        let code = "```\n                x = 1\n\n\n    y = 2\n```"
        XCTAssertEqual(TextNormalizer.compact(code), code)
        XCTAssertEqual(TextNormalizer.compact("                - bullet"), "                - bullet")
    }

    func testLabelFormatsAndCopy() async throws {
        let source = "link<https://example.com/a>\n[The Example Awards] <https://example.com/b>\nTake our survey<https://example.com/c>\n[Markdown](https://example.com/d)"
        let result = try await render(source)
        XCTAssertEqual(result.text, "link ↗\nThe Example Awards ↗\nTake our survey ↗\nMarkdown ↗")
        XCTAssertEqual(result.links.count, 4)
        XCTAssertEqual(result.copyText(NSRange(location: 0, length: result.text.utf16.count)), source)
        XCTAssertEqual(result.copyText(NSRange(location: 0, length: 2)), "li")
    }

    func testProtectionWrapper() async throws {
        let source = "View online<https://gbr01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fsurvey&data=synthetic>"
        let result = try await render(source)
        XCTAssertEqual(result.text, "View online ↗")
        XCTAssertEqual(result.links.first?.url.host, "gbr01.safelinks.protection.outlook.com")
        XCTAssertTrue(result.links.first?.tooltip.contains("Destination: https://example.com/survey") == true)
        XCTAssertEqual(result.copyText(NSRange(location: 0, length: result.text.utf16.count)), source)
        let bare = try await render(String(source.dropFirst("View online<".count).dropLast()))
        XCTAssertLessThan(bare.text.count, 80)
        XCTAssertEqual(bare.links.count, 1)
    }

    func testWrappedLinks() async throws {
        let source = "😀 Survey<https://example.com/survey?first=one&\nsecond=two>\nNext: https://example.org/a, then https://example.net/b.\nContact hello@example.com"
        let result = try await render(source)
        XCTAssertEqual(result.links.count, 4)
        XCTAssertEqual(result.links.first?.url.absoluteString, "https://example.com/survey?first=one&second=two")
        XCTAssertTrue(result.text.contains(", then "))
        XCTAssertEqual(result.copyText(NSRange(location: 0, length: result.text.utf16.count)), source)
        let adjacent = "First<https://example.com/a> Second<https://example.com/b>"
        let pair = try await render(adjacent)
        XCTAssertEqual(pair.links.count, 2)
        XCTAssertEqual(pair.copyText(NSRange(location: 0, length: pair.text.utf16.count)), adjacent)
    }

    func testLimitsAndCode() async throws {
        let source = "```\nhttps://example.com/code\n```\n" + (0..<200).map { "https://example.com/\($0)" }.joined(separator: "\n")
        let result = try await render(source)
        XCTAssertEqual(result.links.count, 128)
        XCTAssertTrue(result.text.contains("https://example.com/code"))
        for value in ["javascript:alert(1)", "file:///tmp/a", "https://user:password@example.com/a"] {
            XCTAssertFalse(PlainRenderer.permits(URL(string: value)!))
        }
        let task = Task { try await render(source) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled rendering completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testOriginalView() async throws {
        let source = "  Original\n\n\n[Label](https://example.com/a)\n"
        let result = try await PlainRenderer.shared.render(source, spacing: .original, links: .original)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.links.isEmpty)
    }

    func testSafeLinkValidation() async throws {
        for url in ["https://safelinks.protection.outlook.com.evil.test/?url=https%3A%2F%2Fexample.test", "https://gbr01.safelinks.protection.outlook.com/?url=javascript%3Aalert%281%29", "https://gbr01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fuser%3Asecret%40example.test"] {
            let result = try await render(url)
            XCTAssertFalse(result.text.contains("[Safe Links]"))
            XCTAssertFalse(result.links.first?.tooltip.contains("Destination:") == true)
        }
    }

    func testPreviewParagraphs() {
        let source = "Hi both,\n\nCongratulations, the review is complete.\n\nNext\t steps are below."
        let result = MessagePreview.render(source)
        XCTAssertEqual(result.text, "Hi both, | Congratulations, the review is complete. | Next steps are below.")
        XCTAssertEqual(result.separators.count, 2)
        XCTAssertTrue(result.separators.allSatisfy { (result.text as NSString).substring(with: $0) == "|" })
        XCTAssertEqual(MessagePreview.render("😀\r\n\r\nSecond line").text, "😀 | Second line")
        XCTAssertLessThanOrEqual(MessagePreview.render(String(repeating: "Paragraph\n", count: 10000)).text.count, 512)
        let padding = String(repeating: "\u{2007}\u{034F}\u{00AD}", count: 128)
        XCTAssertEqual(MessagePreview.render("First" + padding + "\nSecond").text, "First | Second")
    }

    func testLargeBodyBounds() async throws {
        let padding = String(repeating: "\u{2007}\u{034F}\u{00AD}", count: 30)
        let line = "Sample paragraph" + padding + "\nSurvey<https://example.test/survey?data=synthetic>\n\n"
        let source = String(repeating: line, count: 1200)
        let runs = ProcessInfo.processInfo.environment["SQUAREMAIL_TEXT_PROFILE"] == "1" ? 30 : 1
        var times: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            let result = try await PlainRenderer.shared.render(source, spacing: .compact, links: .readable)
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertEqual(result.links.count, 128)
            XCTAssertFalse(result.text.contains(padding))
            XCTAssertEqual(result.copyText(NSRange(location: 0, length: result.text.utf16.count)), TextNormalizer.compact(source))
        }
        if runs > 1 {
            times.sort()
            print("TEXT_PROFILE bytes=\(source.utf8.count) runs=\(runs) median_ms=\(times[runs / 2]) p95_ms=\(times[Int(Double(runs) * 0.95)])")
        }
    }

    func testMailtoDraftOnly() {
        let draft = MailLinkDraft(url: URL(string: "mailto:one@example.com?cc=two%40example.com&bcc=hidden%40example.com&subject=Hello%0AWorld&body=First%0ASecond")!)
        XCTAssertEqual(draft?.to, ["one@example.com"])
        XCTAssertEqual(draft?.cc, ["two@example.com"])
        XCTAssertEqual(draft?.subject, "Hello World")
        XCTAssertEqual(draft?.body, "First\nSecond")
        XCTAssertNil(MailLinkDraft(url: URL(string: "mailto:one@example.com?to=two%40example.com%0ABcc:bad")!))
    }

    func testCompactMailLabels() async throws {
        let safe = "https://gbr01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fshop.example.test%2Ftrack&data=fixture"
        let source = "Shop logo] [Shop logo<\(safe)>\nYour orders<\(safe)> Offers<\(safe)>\n\n\n[Shipment header]\n\n[Completed]\nDispatched\n\n[Pending]\nDelivered"
        let result = try await PlainRenderer.shared.render(source, spacing: .compact, links: .readable, html: "<img alt='Shipment header'><img alt='Shop logo'>")
        XCTAssertEqual(result.text, "Shop logo ↗\nYour orders ↗ Offers ↗\nShipment header\n[Completed]\nDispatched\n[Pending]\nDelivered")
        XCTAssertEqual(result.links.count, 3)
        XCTAssertTrue(result.links.allSatisfy { $0.tooltip.contains("Safe Links protection:") && $0.url.host == "gbr01.safelinks.protection.outlook.com" })
        XCTAssertTrue(result.copyText(NSRange(location: 0, length: result.text.utf16.count)).contains(safe))
        XCTAssertEqual(ImageLabels.clean("[Keep this]\n[Pending]", html: #"<!-- <img alt='Keep this'> --><img title="alt='Pending'" alt='Other'>"#), "[Keep this]\n[Pending]")
        let code = "```\n[Shipment header]\n\n```"
        XCTAssertEqual(ImageLabels.clean(code, html: "<img alt='Shipment header'>"), code)
        let markdown = "[https://claimed.example.test](https://destination.example.test)"
        let namedURL = try await render(markdown)
        XCTAssertEqual(namedURL.links.count, 1)
        XCTAssertEqual(namedURL.text, "https://destination.example.test ↗")
        XCTAssertEqual(namedURL.copyText(NSRange(location: 0, length: namedURL.text.utf16.count)), markdown)
        let duplicate = try await render("[Shop logo] [Shop logo]<https://shop.example.test>")
        XCTAssertEqual(duplicate.text, "Shop logo ↗")
        let repeatLink = "[Product]<https://shop.example.test/item>\nProduct<https://shop.example.test/item>"
        let compact = try await PlainRenderer.shared.render(repeatLink, spacing: .compact, links: .readable)
        XCTAssertEqual(compact.text, "Product ↗")
        XCTAssertEqual(compact.copyText(NSRange(location: 0, length: compact.text.utf16.count)), repeatLink)
        let bareLabel = try await render("Before [Product]https://shop.example.test/item")
        XCTAssertEqual(bareLabel.text, "Before Product ↗")
    }

    private func render(_ text: String) async throws -> PlainDocument {
        try await PlainRenderer.shared.render(text, spacing: .original, links: .readable)
    }
}
