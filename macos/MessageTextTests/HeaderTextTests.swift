import XCTest
@testable import MessageText

final class HeaderTextTests: XCTestCase {
    func testHeaderEscapes() {
        XCTAssertEqual(HeaderText.decode("Salt &amp; Pepper &#39;offers&#x27; &quot;today&quot;"), "Salt & Pepper 'offers' \"today\"")
        XCTAssertEqual(HeaderText.decode("&lt;b&gt;Literal&lt;/b&gt; &copy; &eacute; &rsquo;"), "<b>Literal</b> © é ’")
        XCTAssertEqual(HeaderText.decode("&AMP; &apos; &#X1F4E7; &NotEqualTilde;"), "& ' 📧 \u{2242}\u{338}")
        XCTAssertEqual(HeaderText.decode("A &CounterClockwiseContourIntegral; B"), "A ∳ B")
        XCTAssertEqual(HeaderText.decode("&#128; &#x92;"), "€ ’")
    }
    func testLiteralAndSinglePass() {
        let original = "R&D &unknown; &amp;#39; &copy without a semicolon"
        XCTAssertEqual(HeaderText.decode(original), "R&D &unknown; &#39; &copy without a semicolon")
        XCTAssertEqual(original, "R&D &unknown; &amp;#39; &copy without a semicolon")
        for value in ["&#0;", "&#xD800;", "&#1114112;", "&#999999999999999999999999999999;", "&#-1;", "&#x;", "&#;", "&;"] { XCTAssertEqual(HeaderText.decode(value), value) }
    }
    func testPreviewSpacingAndRanges() {
        let preview = MessagePreview.render("You&#39;re getting noticed&nbsp;&nbsp;today\n\nOffers &amp; updates")
        XCTAssertEqual(preview.text, "You're getting noticed today | Offers & updates")
        XCTAssertEqual(preview.separators.count, 1)
        XCTAssertEqual((preview.text as NSString).substring(with: preview.separators[0]), "|")
    }
    func testBoundedDisplay() {
        XCTAssertEqual(HeaderText.decode(String(repeating: "&amp;", count: 10000)).utf8.count, 1640)
        XCTAssertLessThanOrEqual(HeaderText.decode(String(repeating: "a", count: 100000)).utf8.count, 8192)
    }
}
