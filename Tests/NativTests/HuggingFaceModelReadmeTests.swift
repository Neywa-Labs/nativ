import XCTest

final class HuggingFaceModelReadmeTests: XCTestCase {
    func testDisplayMarkdownRemovesModelCardFrontMatter() {
        let markdown = """
        ---
        license: apache-2.0
        tags:
          - mlx
        ---
        # Model title

        Model details.
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            "# Model title\n\nModel details."
        )
    }

    func testDisplayMarkdownPreservesMarkdownWithoutFrontMatter() {
        let markdown = "\n# Model title\r\n\r\nModel details.\n"

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            "# Model title\n\nModel details."
        )
    }

    func testDisplayMarkdownConvertsCommonModelCardHTML() {
        let markdown = """
        <div align="center">
          <img src=https://ai.google.dev/gemma/images/gemma4_banner.png>
        </div>
        <p align="center">
          <a href="https://huggingface.co/google/gemma-4">Hugging Face</a> |
          <a href="https://github.com/google-deepmind/gemma">GitHub</a><br>
          <b>License:</b> Apache 2.0
        </p>
        """

        let output = HuggingFaceModelReadmeFormatting.displayMarkdown(markdown)
        XCTAssertTrue(output.contains("![](https://ai.google.dev/gemma/images/gemma4_banner.png)"))
        XCTAssertTrue(output.contains("[Hugging Face](https://huggingface.co/google/gemma-4)"))
        XCTAssertTrue(output.contains("[GitHub](https://github.com/google-deepmind/gemma)"))
        XCTAssertTrue(output.contains("**License:** Apache 2.0"))
        XCTAssertFalse(output.contains("    [Hugging Face]"))
        XCTAssertFalse(output.contains("    [GitHub]"))
        XCTAssertFalse(output.contains("<div"))
        XCTAssertFalse(output.contains("<a "))
    }

    func testDisplayMarkdownDoesNotRewriteHTMLInsideCodeFence() {
        let markdown = """
        ```html
        <div>Example</div>
        ```
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            markdown
        )
    }

    func testHTMLImageAndLinkDestinationsPreserveEscapesAndEncodeMarkdownDelimiters() throws {
        let markdown = #"<a href="docs/model (draft.html?x=1&amp;y=2#usage"><img src="assets/model (draft%20v2.png" alt="Model [preview]"></a>"#
        let output = HuggingFaceModelReadmeFormatting.displayMarkdown(markdown)
        let link = try XCTUnwrap(MarkdownParser.parse(output).first?.children.first)
        XCTAssertEqual(link.kind, "link")
        XCTAssertEqual(link.destination, "docs/model%20%28draft.html?x=1&y=2#usage")
        let image = try XCTUnwrap(link.children.first)
        XCTAssertEqual(image.kind, "image")
        XCTAssertEqual(image.destination, "assets/model%20%28draft%20v2.png")
        XCTAssertEqual(image.children.first?.literal, "Model [preview]")
    }

    func testStyledHTMLSeparatorsDoNotExposeTags() {
        let markdown = """
        # Model details
        <hr style="margin: -0.7em 0 1.2em 0; border-top: 1px solid gray;" />
        First line<br class="break" />Second line
        """
        let output = HuggingFaceModelReadmeFormatting.displayMarkdown(markdown)
        XCTAssertFalse(output.contains("<hr"))
        XCTAssertFalse(output.contains("<br"))
        let nodes = MarkdownParser.parse(output)
        XCTAssertEqual(nodes.map(\.kind), ["heading", "thematic_break", "paragraph"])
        XCTAssertEqual(nodes.last?.children.map(\.kind), ["text", "linebreak", "text"])
    }

    func testHTMLTableLineBreaksKeepReadableCellText() {
        let markdown = "<table><tr><td>First<br style=\"clear: both\">Second</td></tr></table>"
        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            "| First Second |\n| --- |")
    }

    func testDisplayMarkdownConvertsHTMLTableIntoCompleteMarkdownRows() {
        let markdown = """
        <table>
          <thead><tr><th>Benchmark</th><th>Model A</th><th>Model B</th></tr></thead>
          <tbody>
            <tr><th>Coding Agent</th><td>88.8</td><td>84.6</td></tr>
            <tr><th colspan="3">Repository tasks</th></tr>
            <tr><td>NL2Repo</td><td>69.4</td><td>47.2</td></tr>
          </tbody>
        </table>
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            """
            | Benchmark | Model A | Model B |
            | --- | --- | --- |
            | **Coding Agent** | 88.8 | 84.6 |
            | **Repository tasks** |  |  |
            | NL2Repo | 69.4 | 47.2 |
            """
        )
    }

    func testRemovingDuplicateLeadingTitleMatchesRepositoryName() {
        let markdown = """
        # North Micro Vision Instruct

        ![](banner.png)

        Model details.
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.removingDuplicateLeadingTitle(
                markdown,
                modelTitle: "North-Micro-Vision-Instruct"
            ),
            "![](banner.png)\n\nModel details."
        )
    }

    func testRemovingDuplicateLeadingTitlePreservesDifferentHeading() {
        let markdown = "# Usage\n\nRun the model."

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.removingDuplicateLeadingTitle(
                markdown,
                modelTitle: "North-Micro-Vision-Instruct"
            ),
            markdown
        )
    }
}
