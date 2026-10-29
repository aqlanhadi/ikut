import Testing

@testable import ikut

@Suite struct ResultFramesTests {
    private typealias Span = ResultFrames.Span
    private let order = ["a", "b", "c", "d"]

    @Test func rowBehindTheBarIsSkipped() {
        // The bar ends at 100: "a" is entirely under it, "b" is the first below.
        let spans = ["a": Span(top: 20, bottom: 90), "b": Span(top: 94, bottom: 160), "c": Span(top: 164, bottom: 230)]
        #expect(ResultFrames.topID(order: order, spans: spans, barBottom: 100) == "b")
    }

    @Test func rowStraddlingTheBarIsTheTop() {
        let spans = ["a": Span(top: 60, bottom: 130), "b": Span(top: 134, bottom: 200)]
        #expect(ResultFrames.topID(order: order, spans: spans, barBottom: 100) == "a")
    }

    @Test func rowTouchingTheBarEdgeIsStillSkipped() {
        let spans = ["a": Span(top: 40, bottom: 100), "b": Span(top: 104, bottom: 170)]
        #expect(ResultFrames.topID(order: order, spans: spans, barBottom: 100) == "b")
    }

    @Test func listEndWithEarlierRowsGone() {
        // Scrolled to the end: the first rows left the screen (no report), the last two remain.
        let spans = ["c": Span(top: 90, bottom: 150), "d": Span(top: 154, bottom: 220)]
        #expect(ResultFrames.topID(order: order, spans: spans, barBottom: 100) == "c")
    }

    @Test func everythingBehindTheBarHasNoTop() {
        let spans = ["c": Span(top: 10, bottom: 60), "d": Span(top: 64, bottom: 90)]
        #expect(ResultFrames.topID(order: order, spans: spans, barBottom: 100) == nil)
    }

    @Test func aShorterSearchIgnoresRowsThatAreNotResultsAnyMore() {
        // "x" was in the old list and its frame is stale; the new list is a, b only.
        let spans = ["x": Span(top: 120, bottom: 180), "b": Span(top: 200, bottom: 260)]
        #expect(ResultFrames.topID(order: ["a", "b"], spans: spans, barBottom: 100) == "b")
        #expect(ResultFrames.topID(order: [], spans: spans, barBottom: 100) == nil)
    }

    @Test func listOrderDecidesNotFramePosition() {
        let spans = ["a": Span(top: 300, bottom: 360), "b": Span(top: 110, bottom: 170)]
        #expect(ResultFrames.topID(order: order, spans: spans, barBottom: 100) == "a")
    }
}
