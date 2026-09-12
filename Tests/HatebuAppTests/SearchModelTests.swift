import XCTest
import HatebuCore
@testable import HatebuApp

final class SearchModelTests: XCTestCase {
    @MainActor func testIncrementalSearchKeepsResultsWhileValidatingAndRejectsOldQueries() async throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try BookmarkDatabase(paths: paths)
        let first = Bookmark(user: "azu",title: "日本語の設計",url: "https://example.com/one",comment: "",tags: [],date: "2026-09-01T00:00:00Z")
        let second = Bookmark(user: "azu",title: "Swift の検索",url: "https://example.com/two",comment: "",tags: [],date: "2026-09-02T00:00:00Z")
        try db.apply([first,second],source: Source(user: "azu"),full: true)
        let model = SearchModel(paths: paths)
        model.query = "日"
        try await waitForSearch(model)
        XCTAssertEqual(model.items,[first])
        XCTAssertNil(model.selectedID,"Completed searches must not automatically select a result")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID,first.id)
        model.scheduleSearch()
        try await waitForSearch(model)
        XCTAssertEqual(model.selectedID,first.id,"Refreshing the same query keeps a deliberate selection")
        model.query = "Swift"
        XCTAssertNil(model.selectedID,"Changing the query clears the old selection")
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.items,[first],"Old results remain usable during validation")
        model.query = "日本語"
        try await waitForSearch(model)
        XCTAssertEqual(model.items,[first],"The older Swift query must not replace the latest query")
        model.query = "after:2026-02-30"
        try await waitForSearch(model)
        XCTAssertNotNil(model.searchError)
        XCTAssertEqual(model.items,[first],"Invalid input must preserve the last usable results")
        model.query = "Swift"
        try await waitForSearch(model)
        XCTAssertEqual(model.items,[second])
        XCTAssertNil(model.searchError)
        XCTAssertNil(model.selectedID)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID,second.id,"Down starts at the first result after completion")
    }
    @MainActor func testEmptyAICandidatesDoNotMasqueradeAsSearchResultsAndInterruptedHistoryRecovers() throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = SearchModel(paths: paths)
        model.items = [Bookmark(user: "azu",title: "Normal result",url: "https://example.com",comment: "",tags: [],date: "2026-09-01T00:00:00Z")]
        model.resultMode = "ai"
        XCTAssertEqual(model.visibleItems,[])
        var history = Conversation()
        history.threadID = "thread-one"
        history.activities = [SearchActivity(id: "search-1",title: "検索中",state: .running)]
        model.restore(history)
        XCTAssertEqual(model.conversation.threadID,"thread-one")
        XCTAssertEqual(model.conversation.activities?.first?.state,.stopped)
    }
    @MainActor func testProgressCandidatesAndStopThenContinueStayInOneConversation() async throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try BookmarkDatabase(paths: paths)
        let item = Bookmark(user: "azu",title: "日本語の検索",url: "https://example.com/known",comment: "メモ",tags: [],date: "2026-09-01T00:00:00Z")
        try db.apply([item],source: Source(user: "azu"),full: true)
        let searchJSON = String(decoding: try JSONEncoder().encode(db.search("日本語")),as: UTF8.self)
        let answerJSON = String(decoding: try JSONEncoder().encode(AIAnswer(message: "条件を変えて見つけました",bookmarkIDs: [item.id,item.id,"unknown-id"])),as: UTF8.self)
        func event(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value),as: UTF8.self) }
        let start = try event(["type":"thread.started","thread_id":"shared-thread"])
        let candidate = try event(["type":"item.completed","item":["id":"search","type":"command_execution","exit_code":0,"aggregated_output":searchJSON]])
        let answer = try event(["type":"item.completed","item":["type":"agent_message","text":answerJSON]])
        let file = paths.root.appendingPathComponent("fake-codex")
        let body = """
        #!/bin/bash
        cat >/dev/null
        cat <<'START'
        \(start)
        \(candidate)
        START
        if [[ " $* " == *" resume shared-thread "* ]]; then
          cat <<'ANSWER'
        \(answer)
        {"type":"turn.completed"}
        ANSWER
          exit 0
        fi
        sleep 60
        """
        try body.write(to: file,atomically: true,encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: file.path)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/hatebu").path
        let model = SearchModel(paths: paths,cli: cli,codex: file.path)
        model.items = [item]; model.draft = "日本語の記事"; model.send()
        for _ in 0..<200 {
            if !model.aiItems.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isThinking)
        XCTAssertEqual(model.aiItems,[item])
        XCTAssertNil(model.selectedID,"Streaming AI candidates must not select themselves")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID,item.id,"Candidates can still be selected while AI is running")
        XCTAssertEqual(model.conversation.activities?.first?.title,"「日本語」 · 1 件")
        XCTAssertEqual(try ConversationStore(paths: paths).list().first?.bookmarkIDs,[item.id],"Candidates must be persisted before the final response")
        let conversationID = model.conversation.id
        model.draft = "もっと入門的な記事"; model.revise()
        XCTAssertTrue(model.isStopping)
        for _ in 0..<700 {
            if !model.isThinking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.shutdown()
        XCTAssertFalse(model.isThinking)
        XCTAssertNil(model.aiError)
        XCTAssertEqual(model.conversation.id,conversationID)
        XCTAssertEqual(model.conversation.threadID,"shared-thread")
        XCTAssertEqual(model.aiItems,[item],"Duplicate and unknown IDs must be filtered")
        XCTAssertEqual(model.conversation.messages.map(\.role),["user","user","assistant"])
        XCTAssertEqual(model.conversation.messages.last?.text,"条件を変えて見つけました")
        XCTAssertEqual(model.conversation.activities?.count,2,"Tool IDs from separate turns must not collide")
        XCTAssertEqual(model.conversation.lastRun?.state,.completed)
        XCTAssertEqual(model.runTitle,"検索完了 · 1 件の候補")
        XCTAssertNil(model.selectedID,"The final AI answer must leave results unselected")
        XCTAssertNotNil(model.conversation.lastRun?.finishedAt)
        XCTAssertTrue(model.conversation.activities!.allSatisfy { $0.state != .running })
        XCTAssertEqual(try ConversationStore(paths: paths).list().first?.lastRun?.state,.completed)
    }
    @MainActor func testCompletedAnswerWithMissingToolEndIsNotFailedOrStillSearching() async throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.prepare()
        let file = paths.root.appendingPathComponent("fake-codex")
        let body = #"""
        #!/bin/bash
        cat >/dev/null
        cat <<'EVENTS'
        {"type":"thread.started","thread_id":"completed-thread"}
        {"type":"item.started","item":{"id":"search-one","type":"command_execution","command":"hatebu search -- 日本語","status":"in_progress"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\"message\":\"候補はありません\",\"bookmarkIDs\":[]}"}}
        {"type":"turn.completed"}
        EVENTS
        """#
        try body.write(to: file,atomically: true,encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: file.path)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/hatebu").path
        let model = SearchModel(paths: paths,cli: cli,codex: file.path)
        model.draft = "日本語"; model.send()
        for _ in 0..<300 {
            if !model.isThinking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { model.shutdown() }
        XCTAssertFalse(model.isThinking)
        XCTAssertNil(model.aiError)
        XCTAssertEqual(model.runTitle,"検索完了 · 0 件の候補")
        XCTAssertEqual(model.conversation.activities?.first?.state,.unconfirmed)
        XCTAssertEqual(model.conversation.activities?.first?.toolName,"hatebu search")
        XCTAssertFalse(model.conversation.activities!.first!.title.contains("調べています"))
        let saved = try XCTUnwrap(ConversationStore(paths: paths).list().first)
        XCTAssertEqual(saved.lastRun?.state,.completed)
        model.restore(saved)
        XCTAssertEqual(model.runTitle,"検索完了 · 0 件の候補")
    }
    @MainActor func testLegacyCompletedAnswerDoesNotShowSearchingOrFalseFailures() throws {
        let paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        let model = SearchModel(paths: paths)
        var value = Conversation(query: "GitHub", bookmarkIDs: ["known"])
        value.messages = [ChatMessage(role: "user",text: "アーカイブ"), ChatMessage(role: "assistant",text: "候補が見つかりました")]
        value.activities = [SearchActivity(id: "old-tool",title: "保存済みのブックマークを調べています",state: .failed)]
        model.restore(value)
        XCTAssertEqual(model.runTitle,"検索完了 · 1 件の候補")
        XCTAssertFalse(model.isThinking)
        XCTAssertEqual(model.conversation.activities?.first?.state,.unconfirmed)
        XCTAssertFalse(model.conversation.activities!.first!.title.contains("調べています"))
        model.newConversation()
        XCTAssertEqual(model.runTitle,"")
    }
    @MainActor func testKeyboardSelectionOpeningAndIMEPolicy() {
        let paths = DataPaths(directory: "/tmp/hatebu-keyboard-tests-" + UUID().uuidString)
        var opened: [URL] = []
        let model = SearchModel(paths: paths, openURL: { opened.append($0) })
        let one = Bookmark(user: "azu",title: "One",url: "https://example.com/one",comment: "",tags: [],date: "2026-09-01T00:00:00Z")
        let two = Bookmark(user: "azu",title: "Two",url: "https://example.com/two",comment: "",tags: [],date: one.date)
        model.items = [one,two]
        model.openSelected(); XCTAssertTrue(opened.isEmpty,"Enter without a selection must not open a page")
        model.moveSelection(by: 1); XCTAssertEqual(model.selectedID,one.id)
        model.moveSelection(by: 1); XCTAssertEqual(model.selectedID,two.id)
        model.moveSelection(by: 1); XCTAssertEqual(model.selectedID,two.id)
        model.openSelected(); XCTAssertEqual(opened,[two.webURL!])
        model.moveSelection(by: -1); XCTAssertEqual(model.selectedID,one.id)
        model.aiItems = [two]; model.resultMode = "ai"
        XCTAssertNil(model.selectedID)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID,two.id)
        model.aiItems = []
        XCTAssertNil(model.selectedID,"Removing the selected result must not select another row")
        XCTAssertEqual(SearchKeyAction.resolve("moveDown:",hasMarkedText: false),.next)
        XCTAssertEqual(SearchKeyAction.resolve("moveUp:",hasMarkedText: false),.previous)
        XCTAssertEqual(SearchKeyAction.resolve("insertNewline:",hasMarkedText: false),.open)
        for selector in ["moveDown:","moveUp:","insertNewline:"] {
            XCTAssertNil(SearchKeyAction.resolve(selector,hasMarkedText: true),"Japanese composition owns this key")
        }
        XCTAssertNil(SearchKeyAction.resolve("insertTab:",hasMarkedText: false))
    }
    @MainActor func testOpenRowUsesItsBookmarkWithoutRequiringSelection() {
        let paths = DataPaths(directory: "/tmp/hatebu-row-open-tests-" + UUID().uuidString)
        var opened: [URL] = []
        let model = SearchModel(paths: paths, openURL: { opened.append($0) })
        let one = Bookmark(user: "azu", title: "One", url: "https://example.com/one", comment: "", tags: [], date: "2026-09-01T00:00:00Z")
        let two = Bookmark(user: "azu", title: "Two", url: "https://example.com/two", comment: "", tags: [], date: one.date)
        model.items = [one, two]
        model.open(two)
        XCTAssertEqual(opened, [two.webURL!], "A row can be opened before anything is selected")
        XCTAssertNil(model.selectedID)
        model.selectedID = one.id
        model.open(two)
        XCTAssertEqual(opened, [two.webURL!, two.webURL!], "Open the clicked row, not the current selection")
        XCTAssertEqual(model.selectedID, one.id)
        model.open(Bookmark(user: "azu", title: "Invalid", url: "file:///tmp/local", comment: "", tags: [], date: one.date))
        XCTAssertEqual(opened.count, 2, "Only web URLs may be opened")
    }
    @MainActor private func waitForSearch(_ model: SearchModel) async throws {
        for _ in 0..<100 {
            if !model.isSearching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not finish within one second")
    }
}
