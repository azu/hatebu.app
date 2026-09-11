import XCTest
@testable import HatebuCore

final class SearchTests: XCTestCase {
    var paths: DataPaths!
    override func setUpWithError() throws {
        paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hatebu-tests-" + UUID().uuidString).path)
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: paths.root.path) { try FileManager.default.removeItem(at: paths.root) } }

    func fixture(_ title: String = "SQLite 日本語の全文検索", comment: String = "[設計][AI]検索の仕組み", url: String = "https://sqlite.org/fts5.html", date: String = "2026-09-01T00:00:00Z") -> Bookmark {
        Bookmark(user: "azu",title: title,url: url,comment: comment,tags: ["設計","AI"],date: date)
    }
    func populate(_ items: [Bookmark]) throws -> BookmarkDatabase {
        let db = try BookmarkDatabase(paths: paths)
        try db.apply(items,source: Source(user: "azu"),full: true)
        return db
    }
    func testQuery() throws {
        let query = try SearchQuery("ＳＱＬｉｔｅ 設計 tag:日本語 site:example.com after:2025-01-01")
        XCTAssertEqual(query.terms, ["sqlite", "設計"])
        XCTAssertEqual(query.tags, ["日本語"])
        XCTAssertEqual(query.site, "example.com")
    }
    func testIncrementalJapaneseShortWordsAndLiteralSymbols() throws {
        let item = fixture(comment: "[設計][AI] 100% 正しい検索 A_B")
        var unrelated = fixture("Other",comment: "unrelated",url: "https://example.com/other")
        unrelated.tags = []
        let db = try populate([item, unrelated])
        for query in ["日", "日本", "日本語", "日本語の全", "設計", "ＡＩ", "sqlite 日本語", "100%", "A_B", "\"日本語の全文検索", "tag:設計", "site:sqlite.org after:2026-08-01 before:2026-10-01"] {
            XCTAssertEqual(try db.search(query).items.map(\.id), [item.id], query)
        }
        XCTAssertTrue(try db.search("日本語 missing").items.isEmpty)
        XCTAssertTrue(try db.search("' OR 1=1 --").items.isEmpty)
        XCTAssertTrue(try db.search("site:lite.org").items.isEmpty)
        XCTAssertThrowsError(try SearchQuery("after:2026-02-30"))
    }
    func testTagAndDomainBoundaries() throws {
        let db = try populate([fixture(),fixture(url: "https://www.sqlite.org/intro")])
        XCTAssertEqual(try db.search("site:sqlite.org").items.count, 2)
        XCTAssertEqual(try db.search("tag:設計").items.count, 2)
        XCTAssertEqual(try db.search("tag:設").items.count, 0)
        XCTAssertEqual(try db.search("before:2026-09-01").items.count, 0)
    }
    func testUpdateDeleteAndSourceIsolation() throws {
        let initial = fixture(), deleted = fixture("古いページ",url: "https://example.com/old")
        let db = try populate([initial,deleted])
        let other = Bookmark(user: "tester",title: "別ユーザー",url: initial.url,comment: "",tags: [],date: initial.date)
        try db.apply([other],source: Source(user: "tester"),full: true)
        var updated = initial; updated.title = "SQLITE 日本語の全文検索"
        try db.apply([updated],source: Source(user: "azu"),full: false)
        XCTAssertEqual(try db.get([initial.id]).first?.title, updated.title)
        XCTAssertEqual(try db.count(), 3)
        try db.apply([updated],source: Source(user: "azu"),full: true)
        XCTAssertEqual(try db.count(), 2)
        XCTAssertTrue(try db.search("古いページ").items.isEmpty)
        XCTAssertEqual(try db.get([other.id]).count, 1)
        try db.apply([],source: Source(user: "azu"),full: true)
        XCTAssertEqual(try db.count(), 1)
    }
    func testInvalidSourceCannotDeleteExistingData() throws {
        let item = fixture(), db = try populate([item])
        XCTAssertThrowsError(try db.apply([item],source: Source(user: "tester"),full: true))
        XCTAssertEqual(try db.count(), 1)
    }
    func testReadOnlySearchDoesNotInitializeOrModifyDatabase() throws {
        XCTAssertEqual(try Cache.search("AI",paths: paths).items.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        let db = try populate([fixture()])
        let before = try Data(contentsOf: paths.database)
        let reader = try BookmarkDatabase(paths: paths,readOnly: true)
        XCTAssertEqual(try reader.search("AI").items.count, 1)
        XCTAssertThrowsError(try reader.addUser("someone"))
        XCTAssertEqual(try Data(contentsOf: paths.database), before)
        withExtendedLifetime(db) {}
    }
    func testLimitAndTitleRanking() throws {
        let db = try populate([fixture(date: "2020-01-01T00:00:00Z"),fixture("別のタイトル",comment: "SQLite",url: "https://example.com/new")])
        let result = try db.search("SQLite",limit: 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.items.first?.title, "SQLite 日本語の全文検索")
    }
    func testOldSearchResultsAreRejected() {
        var generation = SearchGeneration()
        let old = generation.next(), latest = generation.next()
        XCTAssertFalse(generation.accepts(old))
        XCTAssertTrue(generation.accepts(latest))
    }
    func testSearchDuringSyncAndFailurePreservesCache() async throws {
        let db = try populate([fixture()])
        var source = try Source(user: "azu")
        source.cursor = 123; source.lastSuccess = 123; source.lastFullSync = Date().timeIntervalSince1970
        try db.saveSource(source)
        let syncStarted = expectation(description: "sync started")
        let paths = paths!
        let sync = Task {
            try await Synchronizer(paths: paths,fetcher: { _,since in
                XCTAssertEqual(since?.timeIntervalSince1970, 3)
                syncStarted.fulfill()
                try await Task.sleep(for: .milliseconds(150))
                return "invalid response"
            }).sync()
        }
        await fulfillment(of: [syncStarted],timeout: 3)
        XCTAssertTrue(SyncLock.isLocked(paths: paths))
        XCTAssertEqual(try Cache.search("日本語",paths: paths).items.count, 1)
        let report = try await sync.value
        XCTAssertNotNil(report.first?.error)
        XCTAssertEqual(try db.sources().first?.cursor, 123)
        XCTAssertEqual(try db.sources().first?.lastSuccess, 123)
        XCTAssertFalse(try db.sources()[0].isDue()) // Back off before retrying a failed request.
        XCTAssertEqual(try Cache.search("日本語",paths: paths).items.count, 1)
        XCTAssertFalse(SyncLock.isLocked(paths: paths))
    }
    func testSyncLockRejectsConcurrentWriters() throws {
        var lock: SyncLock? = try SyncLock(paths: paths)
        XCTAssertTrue(SyncLock.isLocked(paths: paths))
        XCTAssertThrowsError(try SyncLock(paths: paths))
        withExtendedLifetime(lock) {}
        lock = nil
        XCTAssertFalse(SyncLock.isLocked(paths: paths))
        XCTAssertNoThrow(try SyncLock(paths: paths))
    }
    func testSuccessfulSyncAdvancesCursorAndSkipsFreshCache() async throws {
        let db = try populate([fixture()])
        let text = "Updated title\n[JavaScript]new\nhttps://example.com/new\n1\t20260910123045\n"
        let reports = try await Synchronizer(paths: paths,fetcher: { _,since in XCTAssertNil(since); return text }).sync()
        XCTAssertNil(reports.first?.error)
        XCTAssertEqual(try db.search("Updated").items.count, 1)
        XCTAssertEqual(try db.count(), 1)
        XCTAssertNotNil(try db.sources().first?.cursor)
        let skipped = try await Synchronizer(paths: paths,fetcher: { _,_ in XCTFail("Fresh cache fetched"); return "" }).sync(ifStale: true)
        XCTAssertTrue(skipped.isEmpty)
    }
}
