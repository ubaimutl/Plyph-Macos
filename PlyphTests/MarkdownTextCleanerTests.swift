import XCTest
@testable import Plyph

final class MarkdownTextCleanerTests: XCTestCase {
    func testRemovesCommonBlockAndInlineMarkdown() {
        let markdown = """
        # Result

        > A **clear** answer with [documentation](https://example.com) and `code`.

        - First item
        - [x] Finished item
        - [ ] Open item
        """

        XCTAssertEqual(
            MarkdownTextCleaner.plainText(from: markdown),
            """
            Result

            A clear answer with documentation and code.

            • First item
            ☒ Finished item
            ☐ Open item
            """)
    }

    func testFencedCodeKeepsCodeButRemovesFenceMarkers() {
        let markdown = """
        ```swift
        let user_name = "Ada"
        print(user_name)
        ```
        """

        XCTAssertEqual(
            MarkdownTextCleaner.plainText(from: markdown),
            """
            let user_name = "Ada"
            print(user_name)
            """)
    }

    func testRemovesTableSeparatorAndKeepsTableContent() {
        let markdown = """
        | Name | Status |
        | --- | :---: |
        | Plyph | **Ready** |
        """

        XCTAssertEqual(
            MarkdownTextCleaner.plainText(from: markdown),
            """
            Name\tStatus
            Plyph\tReady
            """)
    }

    func testPlainTextAndIdentifierUnderscoresRemainUnchanged() {
        let plain = "Use user_name and keep ordinary punctuation."
        XCTAssertEqual(MarkdownTextCleaner.plainText(from: plain), plain)
    }
}
