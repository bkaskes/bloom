import Testing
@testable import BloomCore

@Suite("Streaming Markdown settling")
struct StreamingMarkdownSettlerTests {
    static let answers = [
        """
        I added the setting. Three things changed:

        1. The loader reads `chat.width`.
        2. The view uses it.

        3. A test covers it.

        ## Why

        The old value was ignored.
        Nothing else read it.

        - first point
        - second point

          with a continuation

        - third point

        > quoted line
        > another

        Done.
        """,
        """
        Here is the code:

        ```swift
        let a = 1

        let b = 2
        ```

        | Column | Value |
        | --- | --- |
        | a | 1 |
        | b | 2 |

        Title
        =====

        ---

            indented code

            more indented code

        Last paragraph with **bold** and a [link](https://example.com).
        """,
        """
        a | b

        |---|---|

        - [ ] task one
        - [x] task two

        Final words.

        """,
    ]

    /// Every prefix the stream could stop at, fed to one settler in order, must draw the blocks the
    /// whole prefix parses to. That is the only promise the live tail needs.
    @Test("settled pieces and the rest parse to the blocks of the whole prefix", arguments: answers)
    func matchesWholeParse(answer: String) {
        var settler = StreamingMarkdownSettler()
        var drawn: [MarkdownBlock] = []
        var end = answer.startIndex
        while end < answer.endIndex {
            end = answer.index(after: end)
            let prefix = String(answer[..<end])
            let step = settler.advance(to: prefix)
            #expect(!step.reset)
            if let settled = step.settled { drawn += MarkdownParser.parse(settled) }
            #expect(drawn + MarkdownParser.parse(step.rest) == MarkdownParser.parse(prefix))
        }
    }

    @Test("a long answer settles most of itself")
    func settles() {
        var settler = StreamingMarkdownSettler()
        let text = (1...20).map { "Paragraph \($0) of the answer." }.joined(separator: "\n\n") + "\n\nStill wri"
        let step = settler.advance(to: text)
        #expect(step.settled?.hasPrefix("Paragraph 1 of") == true)
        #expect(step.rest == "Paragraph 19 of the answer.\n\nParagraph 20 of the answer.\n\nStill wri")
    }

    @Test("text that no longer starts with what settled starts over")
    func resets() {
        var settler = StreamingMarkdownSettler()
        let first = (1...5).map { "Line \($0)." }.joined(separator: "\n\n") + "\n\nx"
        _ = settler.advance(to: first)
        #expect(!settler.consumed.isEmpty)
        let step = settler.advance(to: "Something else entirely.")
        #expect(step.reset)
        #expect(step.rest == "Something else entirely.")
    }
}
