import XCTest
import SwiftUI
import HatebuCore
@testable import HatebuApp

final class ResultsLayoutTests: XCTestCase {
    @MainActor func testRealScrollViewKeepsItsExtentAndCanReachAnUnrenderedRow() async throws {
        let items = (0..<100).map {
            Bookmark(user: "azu", title: "Article \($0)", url: "https://example.com/\($0)", comment: "", tags: [], date: "2026-09-12")
        }
        var constructed: Set<String> = []
        func list(selected: String?) -> some View {
            BufferedResultsList(items: items, selectedID: selected, resetKey: [""], onKey: { _ in }) { item, _ in
                constructed.insert(item.id)
                return Text(item.title).frame(height: ResultRowLayout.height)
            }.frame(width: 700, height: 640)
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let hosting = NSHostingView(rootView: list(selected: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 640)
        // Attach to an unshown test window so SwiftUI receives a real viewport.
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<100 {
            hosting.layoutSubtreeIfNeeded()
            if scrollView(in: hosting)?.documentView?.frame.height == 16_000 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        let document = try XCTUnwrap(scroll.documentView)
        let total = document.frame.height
        XCTAssertEqual(total, 16_000, accuracy: 0.5, "All 100 row positions must exist before scrolling")
        XCTAssertLessThanOrEqual(constructed.count, 9, "Distant rows should reserve space without constructing their content")
        XCTAssertFalse(constructed.contains(items.last!.id))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 8000))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<100 {
            hosting.layoutSubtreeIfNeeded()
            if constructed.contains(items[50].id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(constructed.contains(items[50].id), "Scrolling must materialize the newly visible rows")
        XCTAssertFalse(constructed.contains(items.last!.id))
        XCTAssertEqual(document.frame.height, total, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 8000, accuracy: 0.5)
        hosting.rootView = list(selected: items.last!.id)
        for _ in 0..<100 {
            hosting.layoutSubtreeIfNeeded()
            if scroll.contentView.bounds.maxY >= total - 0.5, constructed.contains(items.last!.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(document.frame.height, total, accuracy: 0.5)
        XCTAssertTrue(constructed.contains(items.last!.id))
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, total - 0.5, "Selection must reach a row whose content was not yet rendered")
    }

    func testScrollingAlwaysKeepsVisibleRowsAndOneScreenOfBuffer() {
        let layout = ResultRowLayout(count: 100)
        let viewport: CGFloat = 750
        let total = layout.contentHeight
        for offset in stride(from: CGFloat(0), through: total - viewport, by: 37) {
            let rows = layout.rows(at: offset, viewportHeight: viewport)
            let visibleTop = Int(floor(offset / ResultRowLayout.height))
            let visibleBottom = Int(floor((offset + viewport - 1) / ResultRowLayout.height))
            XCTAssertTrue(rows.contains(visibleTop))
            XCTAssertTrue(rows.contains(visibleBottom))
            XCTAssertLessThanOrEqual(CGFloat(rows.lowerBound) * ResultRowLayout.height, max(0, offset - viewport))
            XCTAssertGreaterThanOrEqual(CGFloat(rows.upperBound) * ResultRowLayout.height, min(total, offset + 2 * viewport))
            XCTAssertLessThanOrEqual(rows.count, 16, "Only nearby row content should be built out of 100 results")
            XCTAssertEqual(layout.contentHeight, total, "Materializing rows must not change the scrollable height")
        }
    }

    func testOverscrollAndShortResultSetsStayWithinAvailableRows() {
        let layout = ResultRowLayout(count: 100)
        XCTAssertEqual(layout.rows(at: -500, viewportHeight: 640), layout.rows(at: 0, viewportHeight: 640))
        XCTAssertEqual(layout.rows(at: 50_000, viewportHeight: 640), 92..<100)
        XCTAssertEqual(ResultRowLayout(count: 2).rows(at: 50_000, viewportHeight: 640), 0..<2)
        XCTAssertEqual(ResultRowLayout(count: 0).rows(at: 0, viewportHeight: 640), 0..<0)
        XCTAssertEqual(layout.rows(at: 0, viewportHeight: 0), 0..<0)
    }

    @MainActor func testRowsReserveTheSameHeightForLongTextAndMissingFieldsAtDifferentWidths() {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let cache = FaviconCache(paths: paths) { _ in Data() }
        let items = [
            Bookmark(user: "azu", title: "短いタイトル", url: "https://example.com", comment: "", tags: [], date: "2026-09-12"),
            Bookmark(user: "azu", title: String(repeating: "長い記事のタイトル ", count: 30), url: "https://example.com/article",
                     comment: String(repeating: "長いコメントと検索語。", count: 50), tags: ["very-long-tag-name", "日本語", "Swift", "UI"], date: "2026-09-12")
        ]
        for width: CGFloat in [410, 700, 1100] {
            for item in items {
                let row = BookmarkRow(item: item, terms: ["記事", "検索語"], favicons: cache, onSelect: {}, onOpen: {})
                let hosting = NSHostingView(rootView: row.frame(width: width))
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: ResultRowLayout.height)
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.fittingSize.height, ResultRowLayout.height, accuracy: 0.5)
            }
        }
    }
}
