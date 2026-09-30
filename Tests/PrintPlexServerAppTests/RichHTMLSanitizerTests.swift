import XCTest
@testable import PrintPlexServerApp

/// Covers the Lot 5 server-side sanitizer for the description/notes rich
/// editor: the client already sanitizes on paste/save, but a direct API call
/// can bypass it, and this content is re-serialized to Shopify.
final class RichHTMLSanitizerTests: XCTestCase {
    func testKeepsAllowedTags() {
        let input = "<p>Hello <strong>world</strong> <em>!</em></p><ul><li>one</li><li>two</li></ul>line<br>break"
        XCTAssertEqual(RichHTMLSanitizer.sanitize(input), input)
    }

    func testStripsScriptAndStyleWithContent() {
        let input = "<p>Safe</p><script>alert(1)</script><style>body{color:red}</style><p>Also safe</p>"
        XCTAssertEqual(RichHTMLSanitizer.sanitize(input), "<p>Safe</p><p>Also safe</p>")
    }

    func testUnwrapsDisallowedTagsKeepingText() {
        let input = "<div class=\"x\"><span onclick=\"evil()\">kept text</span></div>"
        XCTAssertEqual(RichHTMLSanitizer.sanitize(input), "kept text")
    }

    func testStripsAttributesFromAllowedTags() {
        let input = "<p style=\"color:red\" onclick=\"evil()\">text</p>"
        XCTAssertEqual(RichHTMLSanitizer.sanitize(input), "<p>text</p>")
    }

    func testAnchorKeepsOnlySafeSchemeAndAllowlistedAttributes() {
        let safe = "<a href=\"https://example.com\" title=\"Example\" target=\"_blank\" onclick=\"evil()\">link</a>"
        XCTAssertEqual(
            RichHTMLSanitizer.sanitize(safe),
            "<a href=\"https://example.com\" rel=\"noopener noreferrer\" title=\"Example\" target=\"_blank\">link</a>"
        )

        let unsafe = "<a href=\"javascript:alert(1)\">click me</a>"
        XCTAssertEqual(RichHTMLSanitizer.sanitize(unsafe), "<a>click me</a>")
    }
}
