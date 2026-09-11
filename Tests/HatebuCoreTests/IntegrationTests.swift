import XCTest
import CSQLite
@testable import HatebuCore

final class IntegrationTests: XCTestCase {
    func testHatenaFormatAndTokyoTimestamp() throws {
        let text = "Title\n[設計][AI]メモ\nhttps://example.com/a\nSecond\n\nhttps://example.com/b\n3\t20260910123045\n0\t20260910000000\n"
        let items = try HatenaParser.parse(text,user: "azu")
        XCTAssertEqual(items.count,2)
        XCTAssertEqual(items[0].tags,["設計","AI"])
        XCTAssertEqual(items[0].date,"2026-09-10T03:30:45Z")
        XCTAssertEqual(items[1].comment,"")
        XCTAssertEqual(try HatenaParser.parse("",user: "azu"),[])
        for address in ["javascript:alert(1)","about:blank","http://", "file:///tmp/example"] {
            let legacy = try HatenaParser.parse("Title\n\n\(address)\n1\t20260910000000",user: "azu")
            XCTAssertEqual(legacy.first?.url,address)
            XCTAssertNil(legacy.first?.webURL)
            let result = SearchResult(query: "Title",items: legacy,elapsedMilliseconds: 0,hasMore: false)
            let json = try JSONSerialization.jsonObject(with: Alfred.output(result: result,status: CacheStatus(count: 1,sources: [],syncing: false))) as! [String: Any]
            XCTAssertEqual((json["items"] as? [[String: Any]])?.first?["valid"] as? Bool,false)
        }
        XCTAssertThrowsError(try HatenaParser.parse("<html>Server error</html>",user: "azu"))
        XCTAssertThrowsError(try Source(user: "../other"))
    }
    func testAlfredKeepsCachedResultsAndRerunsWhileRefreshing() throws {
        let item = Bookmark(user: "azu",title: "記事",url: "https://example.com",comment: "メモ",tags: [],date: "2026-09-01T00:00:00Z")
        let result = SearchResult(query: "日本語 & \"文字\"",items: [item],elapsedMilliseconds: 1,hasMore: false)
        var source = try Source(user: "azu"); source.lastSuccess = Date().timeIntervalSince1970
        let refreshing = try JSONSerialization.jsonObject(with: Alfred.output(result: result,status: CacheStatus(count: 1,sources: [source],syncing: true))) as! [String: Any]
        XCTAssertEqual(refreshing["rerun"] as? Double,1)
        let items = refreshing["items"] as! [[String: Any]]
        XCTAssertEqual(items[0]["arg"] as? String,item.url)
        XCTAssertNil(items[0]["uid"]) // Alfred must preserve core ranking.
        let mods = items[0]["mods"] as! [String: [String: Any]]
        let link = URL(string: mods["cmd"]!["arg"] as! String)!
        XCTAssertEqual(Handoff(url: link),Handoff(query: result.query,bookmarkID: item.id))
        let fresh = try JSONSerialization.jsonObject(with: Alfred.output(result: result,status: CacheStatus(count: 1,sources: [source],syncing: false))) as! [String: Any]
        XCTAssertNil(fresh["rerun"])
        XCTAssertNil(fresh["cache"])
        XCTAssertNil(Handoff(url: URL(string: "https://example.com/search?q=bad")!))
    }
    func testCodexEventsAcrossByteBoundaries() throws {
        let answer = AIAnswer(message: "日本語の候補です",bookmarkIDs: ["known"])
        let answerJSON = String(decoding: try JSONEncoder().encode(answer),as: UTF8.self)
        let events: [[String: Any]] = [
            ["type":"thread.started","thread_id":"thread-one"],
            ["type":"item.completed","item":["type":"agent_message","text":answerJSON]],
            ["type":"turn.completed"]
        ]
        let data = events.map { try! JSONSerialization.data(withJSONObject: $0) }.reduce(Data()) { $0 + $1 + Data([10]) }
        var parser = CodexEventParser(), output: [CodexEvent] = []
        for byte in data { output += parser.append(Data([byte])) }
        output += parser.finish()
        XCTAssertEqual(output,[.thread("thread-one"),.answer(answer),.completed])
        XCTAssertEqual(parser.append(Data("{\"type\":\"error\",\"message\":\"offline\"}".utf8)),[])
        XCTAssertEqual(parser.finish(),[.failure("offline")])
    }
    func testExistingKeychainLoginPreferenceSurvivesConfigIsolation() {
        XCTAssertEqual(CodexRunner.authStorage(in: "# login\ncli_auth_credentials_store = 'keyring' # macOS\n[mcp_servers.other]\n"),"keyring")
        XCTAssertEqual(CodexRunner.authStorage(in: "\"cli_auth_credentials_store\" = \"file\"\n"),"file")
        XCTAssertNil(CodexRunner.authStorage(in: "[profiles.other]\ncli_auth_credentials_store = 'file'"))
        XCTAssertNil(CodexRunner.authStorage(in: "cli_auth_credentials_store = 'unrecognized'"))
        let args = CodexRunner.arguments(threadID: "thread-one",schema: "/tmp/answer.json",authStorage: "keyring")
        XCTAssertTrue(args.contains("cli_auth_credentials_store=\"keyring\""))
        XCTAssertTrue(args.contains("--ignore-user-config"))
    }
    func testPaginationDoesNotLoseOlderBookmarksOrAcceptRepeatedPages() async throws {
        let first = "One\n\nhttps://example.com/1\nTwo\n\nhttps://example.com/2\n1\t20260910000000\n1\t20260909000000"
        let last = "Three\n\nhttps://example.com/3\n1\t20260908000000"
        let items = try await Synchronizer.fetchAll(user: "azu",since: nil,pageSize: 2) { _,_,offset,limit in
            XCTAssertEqual(limit,2)
            XCTAssertTrue([0,2].contains(offset))
            return offset == 0 ? first : last
        }
        XCTAssertEqual(items.map(\.title),["One","Two","Three"])
        let records = (0..<10).map { "Item \($0)\n\nhttps://example.com/\($0)" }
        let fullPage = (records + Array(repeating: "1\t20260910000000",count: 10)).joined(separator: "\n")
        let overlapOnly = records.last! + "\n1\t20260910000000"
        let exact = try await Synchronizer.fetchAll(user: "azu",since: nil,pageSize: 10) { _,_,offset,_ in
            XCTAssertTrue([0,9].contains(offset))
            return offset == 0 ? fullPage : overlapOnly
        }
        XCTAssertEqual(exact.count,10,"A final short page containing only the overlap is valid")
        do {
            _ = try await Synchronizer.fetchAll(user: "azu",since: nil,pageSize: 2) { _,_,_,_ in first }
            XCTFail("A repeated page must not be accepted as a full snapshot")
        } catch { XCTAssertTrue(error.localizedDescription.contains("続き")) }
    }
    func testCommitFailureRollsBackDataAndCursor() async throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try BookmarkDatabase(paths: paths)
        var source = try Source(user: "azu")
        source.cursor = 10; source.lastSuccess = 20; source.lastFullSync = 30
        let original = Bookmark(user: "azu",title: "Keep",url: "https://example.com/old",comment: "",tags: [],date: "2026-09-01T00:00:00Z")
        try db.apply([original],source: source,full: true)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(paths.database.path,&connection),SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER fail_insert BEFORE INSERT ON bookmarks BEGIN SELECT RAISE(ABORT,'test disk failure'); END;",nil,nil,nil),SQLITE_OK)
        let sync = Synchronizer(paths: paths) { _,_ in "New\n\nhttps://example.com/new\n1\t20260910000000" }
        let report = try await sync.sync(full: true)
        XCTAssertNotNil(report.first?.error)
        let saved = try XCTUnwrap(db.sources().first)
        XCTAssertEqual(saved.cursor,source.cursor)
        XCTAssertEqual(saved.lastSuccess,source.lastSuccess)
        XCTAssertEqual(saved.lastFullSync,source.lastFullSync)
        XCTAssertFalse(saved.isDue())
        XCTAssertEqual(try db.get([original.id]),[original])
    }
    func testConversationPersistsExactThreadAndCandidates() throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var value = Conversation(query: "日本語",bookmarkIDs: ["one"])
        value.threadID = "thread-specific"
        value.messages.append(ChatMessage(role: "user",text: "去年の記事"))
        value.activities = [SearchActivity(id: "turn-one:search-one",title: "日本語 · 3 件",state: .completed)]
        let store = ConversationStore(paths: paths)
        try store.save(value)
        let loaded = try XCTUnwrap(store.list().first)
        XCTAssertEqual(loaded.id,value.id)
        XCTAssertEqual(loaded.threadID,value.threadID)
        XCTAssertEqual(loaded.bookmarkIDs,value.bookmarkIDs)
        XCTAssertEqual(loaded.activities,value.activities)
        let args = CodexRunner.arguments(threadID: loaded.threadID,schema: "/tmp/schema.json")
        XCTAssertTrue(args.contains("thread-specific")); XCTAssertTrue(args.contains("resume"))
        XCTAssertFalse(args.contains("--last")); XCTAssertFalse(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("read-only"))
    }
}
