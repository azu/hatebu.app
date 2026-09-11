import XCTest
@testable import HatebuCore

final class PresentationTests: XCTestCase {
    func testHighlightsPreserveFullWidthCombiningCharactersAndOverlaps() throws {
        let text = "ＳＱＬｉｔｅ / 日本語の検索 / Cafe\u{301} / 👩‍💻 / ﬃ"
        let spans = SearchHighlight.ranges(in: text, terms: ["sqlite", "日本", "日本語", "検索", "café", "👩‍💻", "fi"])
        let values = spans.compactMap { Range($0, in: text).map { String(text[$0]) } }
        XCTAssertEqual(values,["ＳＱＬｉｔｅ", "日本語", "検索", "Cafe\u{301}", "👩‍💻", "ﬃ"])
        XCTAssertEqual(SearchHighlight.ranges(in: "aaaa", terms: ["aaa"]),[NSRange(location: 0, length: 4)])
        XCTAssertTrue(SearchHighlight.ranges(in: text, terms: ["unmatched", ""]).isEmpty)
    }
    func testCommandToolsHaveNamesQueriesAndRunningUpdates() throws {
        let command = "'/Applications/Hatebu Search.app/Contents/MacOS/hatebu' --data-dir '/tmp/search cache' search --format json --limit 30 -- 'GitHub アーカイブ'"
        var parser = CodexEventParser()
        func feed(_ type: String, _ item: [String: Any]) throws -> [CodexEvent] {
            parser.append(try JSONSerialization.data(withJSONObject: ["type":type,"item":item]) + Data([10]))
        }
        let initial = try feed("item.started",["id":"one","type":"command_execution","command":command,"status":"in_progress"])
        guard case .activity(let activity) = initial.first else { return XCTFail("Missing tool") }
        XCTAssertEqual(activity.toolName,"hatebu search")
        XCTAssertEqual(activity.query,"GitHub アーカイブ")
        XCTAssertEqual(activity.command,command)
        XCTAssertEqual(activity.state,.running)
        let output = #"{"query":"GitHub アーカイブ","items":[],"elapsedMilliseconds":1,"hasMore":false}"#
        let update = try feed("item.updated",["id":"one","type":"command_execution","command":command,"status":"in_progress","aggregated_output":output])
        XCTAssertTrue(update.contains(.candidateIDs([])))
        guard case .activity(let updated) = update.first else { return XCTFail("Missing update") }
        XCTAssertEqual(updated.state,.running,"A result is not evidence of process exit")
        XCTAssertEqual(updated.title,"「GitHub アーカイブ」 · 0 件")
        let finished = try feed("item.completed",["id":"one","type":"command_execution","command":command,"status":"completed","exit_code":0,"aggregated_output":output])
        guard case .activity(let final) = finished.first else { return XCTFail("Missing completion") }
        XCTAssertEqual(final.state,.completed)
        let show = ToolPresentation(command: "/bin/zsh -lc \"/tmp/hatebu show one two --format json\"")
        XCTAssertEqual(show.name,"hatebu show")
        XCTAssertEqual(show.title,"候補の詳細を確認")
    }
    func testMCPToolAndActualFailureAreVisible() throws {
        var parser = CodexEventParser()
        let input: [[String: Any]] = [
            ["type":"item.completed","item":["id":"mcp","type":"mcp_tool_call","server":"bookmarks","tool":"search","status":"completed","error":NSNull(),"result":["content":[["type":"text","text":#"{"query":"日本語","items":[],"elapsedMilliseconds":1,"hasMore":false}"#]]]]],
            ["type":"item.completed","item":["id":"denied","type":"command_execution","command":"hatebu search AI","status":"declined"]]
        ]
        let events = try input.flatMap { parser.append(try JSONSerialization.data(withJSONObject: $0) + Data([10])) }
        let activities = events.compactMap { event -> SearchActivity? in if case .activity(let value) = event { return value }; return nil }
        XCTAssertEqual(activities.map(\.toolName),["bookmarks.search", "hatebu search"])
        XCTAssertEqual(activities.map(\.state),[.completed,.failed])
        XCTAssertEqual(activities.first?.title,"「日本語」 · 0 件")
    }
}
