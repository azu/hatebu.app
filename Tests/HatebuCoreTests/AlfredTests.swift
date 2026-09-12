import XCTest
@testable import HatebuCore

final class AlfredTests: XCTestCase {
    private func output(comment: String, tags: [String] = [], title: String = "記事",
                        url: String = "https://example.com/記事?q=a&b=%22c%22") throws -> [String: Any] {
        let bookmark = Bookmark(user: "azu", title: title, url: url, comment: comment, tags: tags, date: "2026-09-12T00:00:00Z")
        let result = SearchResult(query: "日本語 & \"検索\"", items: [bookmark], elapsedMilliseconds: 1, hasMore: false)
        let data = try Alfred.output(result: result, status: CacheStatus(count: 1, sources: [], syncing: false))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((response["items"] as? [[String: Any]])?.first)
    }

    private func detail(_ output: [String: Any]) throws -> [String: Any] {
        let mods = try XCTUnwrap(output["mods"] as? [String: [String: Any]])
        return try XCTUnwrap(mods["alt"])
    }

    func testCommentComesBeforeMetadataAndPrefixTagsMoveToDetails() throws {
        let item = try output(comment: "[React][document]React DOM の API。\n\t続きの説明。", tags: ["React", "document"])
        let subtitle = try XCTUnwrap(item["subtitle"] as? String)
        XCTAssertTrue(subtitle.hasPrefix("React DOM の API。 続きの説明。 · example.com · 2026-09-12"))
        XCTAssertFalse(subtitle.contains("[React]"))
        let markdown = try XCTUnwrap(detail(item)["arg"] as? String)
        XCTAssertTrue(markdown.contains("React DOM の API。  \n\t続きの説明。"))
        XCTAssertTrue(markdown.contains("**タグ**　React · document"))
    }

    func testOnlyKnownLeadingTagsAreRemoved() throws {
        for comment in ["[注記]説明 [React]", "説明 [React]", "[[React]]説明"] {
            let item = try output(comment: comment, tags: ["React"])
            XCTAssertTrue((item["subtitle"] as? String)?.hasPrefix(comment + " · ") == true)
        }
        let item = try output(comment: " [React] [注記]本文 [React] ", tags: ["React"])
        XCTAssertTrue((item["subtitle"] as? String)?.hasPrefix("[注記]本文 [React] · ") == true)
    }

    func testFullCommentIsLiteralTextAndURLIsPassedSeparately() throws {
        let comment = "# 見出し\r\n![画像](https://example.com/image) <script> `code` &amp;\n" + String(repeating: "長いコメント。", count: 100)
        let item = try output(comment: comment, title: "*タイトル*\n別の行")
        let alt = try detail(item)
        let markdown = try XCTUnwrap(alt["arg"] as? String)
        XCTAssertTrue(markdown.hasPrefix("# \\*タイトル\\* 別の行\n\n\\# 見出し  \n"))
        XCTAssertTrue(markdown.contains("\\!\\[画像\\]\\(https\\:\\/\\/example\\.com\\/image\\) \\<script\\> \\`code\\` \\&amp\\;"))
        XCTAssertTrue(markdown.contains(String(repeating: "長いコメント。", count: 100)))
        let variables = try XCTUnwrap(alt["variables"] as? [String: String])
        XCTAssertEqual(variables["bookmark_url"], item["arg"] as? String)
        let bookmark = Bookmark(user: "azu", title: "", url: item["arg"] as! String, comment: "", tags: [], date: "")
        let link = try XCTUnwrap(variables["bookmark_handoff"].flatMap(URL.init(string:)))
        XCTAssertEqual(Handoff(url: link), Handoff(query: "日本語 & \"検索\"", bookmarkID: bookmark.id))
        XCTAssertEqual(alt["valid"] as? Bool, true)
    }

    func testEmptyCommentKeepsMetadataAndTags() throws {
        for comment in ["", "   \n", "[React]"] {
            let item = try output(comment: comment, tags: ["React"])
            XCTAssertEqual(item["subtitle"] as? String, "コメントなし · example.com · 2026-09-12")
            let markdown = try XCTUnwrap(detail(item)["arg"] as? String)
            XCTAssertTrue(markdown.contains("\n\nコメントなし\n\n"))
            XCTAssertTrue(markdown.contains("**タグ**　React"))
        }
    }

    func testNonBookmarkRowsAndUnsafeURLsCannotOpenDetailActions() throws {
        for url in ["javascript:alert(1)", "file:///tmp/example", "https://"] {
            let item = try output(comment: "コメント", url: url)
            XCTAssertEqual(item["valid"] as? Bool, false)
            XCTAssertEqual(try detail(item)["valid"] as? Bool, false)
        }
        let empty = SearchResult(query: "条件", items: [], elapsedMilliseconds: 0, hasMore: false)
        for data in [
            try Alfred.failure("失敗", query: "条件"),
            try Alfred.output(result: empty, status: CacheStatus(count: 0, sources: [], syncing: false)),
            try Alfred.output(result: empty, status: CacheStatus(count: 0, sources: [Source(user: "azu")], syncing: false))
        ] {
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for item in try XCTUnwrap(response["items"] as? [[String: Any]]) {
                XCTAssertEqual(try detail(item)["valid"] as? Bool, false)
            }
        }
    }
}
