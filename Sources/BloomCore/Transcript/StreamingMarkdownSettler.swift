import Foundation

/// Which part of a streaming answer can no longer change, so it is drawn once and kept.
///
/// The live tail used to parse the whole answer so far as Markdown and rebuild its attributed
/// string on every redraw, twenty times a second, so a turn streaming n chunks did O(n²) work and
/// a long answer got choppier the longer it ran. The note on `streamFlushInterval` in
/// `TranscriptModel` has the measurement: 6.6 ms of main thread per redraw on a 1,582 row chat.
///
/// The cut rests on the property `TranscriptAnswerParts` already depends on: a top-level block is
/// read from its own first line onwards with nothing carried over, so text cut where a block
/// starts parses to the same blocks on either side. What is not yet known is where the blocks at
/// the end of a growing answer stop: the last line is still being written, a list may take another
/// item after a blank line, and a paragraph's end can depend on the line after it (a table's
/// delimiter row). So only blocks that end on complete lines settle, and the last two of those
/// stay with the tail, which is the margin those look-aheads need.
public struct StreamingMarkdownSettler: Sendable {
    /// What one call found.
    public struct Step: Equatable, Sendable {
        /// The text no longer starts with what had settled, so whatever was drawn from it is void.
        public var reset: Bool
        /// Markdown that settled with this call, to be drawn and appended after what settled before.
        public var settled: String?
        /// The rest of the answer, drawn again on every call.
        public var rest: String
    }

    /// Source text that has settled, always ending in a newline at a block boundary.
    public private(set) var consumed = ""

    public init() {}

    public mutating func advance(to text: String) -> Step {
        var reset = false
        if !text.utf8.starts(with: consumed.utf8) {
            consumed = ""
            reset = true
        }
        // `consumed` ends just after a newline, which is always a character boundary.
        let tail = String(text.utf8.dropFirst(consumed.utf8.count)) ?? text
        let (lines, blocks) = MarkdownParser.topLevelBlocks(of: tail)
        // The last line has no newline after it yet, or is the empty string after one: either way
        // it is the line still being written.
        let complete = blocks.filter { $0.upperBound < lines.count }
        guard complete.count > 2, let first = complete.first, !tail.contains("\r") else {
            return Step(reset: reset, settled: nil, rest: tail)
        }
        let settling = complete.dropLast(2)
        let cut = complete[settling.count].lowerBound
        let settled = lines[first.lowerBound..<(settling.last?.upperBound ?? first.upperBound)]
            .joined(separator: "\n")
        consumed += lines[0..<cut].joined(separator: "\n") + "\n"
        return Step(reset: reset, settled: settled, rest: lines[cut...].joined(separator: "\n"))
    }
}
