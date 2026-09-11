import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class BookmarkDatabase {
    private var db: OpaquePointer?
    private let readOnly: Bool

    public init(paths: DataPaths, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        if !readOnly { try paths.prepare() }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(paths.database.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db); db = nil
            throw HatebuError("検索データを開けません: \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try migrate()
        }
        let version = try rows("PRAGMA user_version").first?.first ?? "0"
        guard version == "1" else { throw HatebuError("検索データの形式が未対応です。アプリと Workflow を同じ版に更新してください。") }
    }
    deinit { sqlite3_close(db) }

    private func migrate() throws {
        let version = try rows("PRAGMA user_version").first?.first ?? "0"
        guard version == "0" else { return }
        try execute("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS sources(user TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS bookmarks(
            id TEXT NOT NULL UNIQUE, user TEXT NOT NULL REFERENCES sources(user) ON DELETE CASCADE,
            title TEXT NOT NULL, title_normalized TEXT NOT NULL, url TEXT NOT NULL,
            comment TEXT NOT NULL, tags TEXT NOT NULL, tag_text TEXT NOT NULL,
            date TEXT NOT NULL, host TEXT NOT NULL, search_text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS bookmarks_user ON bookmarks(user);
        CREATE INDEX IF NOT EXISTS bookmarks_date ON bookmarks(date DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_fts USING fts5(search_text, content='bookmarks', content_rowid='rowid', tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS bookmarks_ai AFTER INSERT ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(rowid, search_text) VALUES(new.rowid,new.search_text);
        END;
        CREATE TRIGGER IF NOT EXISTS bookmarks_ad AFTER DELETE ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(bookmarks_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text);
        END;
        CREATE TRIGGER IF NOT EXISTS bookmarks_au AFTER UPDATE ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(bookmarks_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text);
            INSERT INTO bookmarks_fts(rowid,search_text) VALUES(new.rowid,new.search_text);
        END;
        PRAGMA user_version=1;
        COMMIT;
        """)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> HatebuError { HatebuError("検索データの処理に失敗しました: \(String(cString: sqlite3_errmsg(db)))") }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) == SQLITE_OK else {
                sqlite3_finalize(statement); throw failure()
            }
        }
        return statement
    }
    private func run(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var output: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw failure() }
            output.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
    }
    public func sources() throws -> [Source] {
        try rows("SELECT json FROM sources ORDER BY user").map { try JSONDecoder().decode(Source.self, from: Data($0[0].utf8)) }
    }
    public func saveSource(_ source: Source) throws {
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        try run("INSERT INTO sources(user,json) VALUES(?,?) ON CONFLICT(user) DO UPDATE SET json=excluded.json", [source.user, json])
    }
    public func addUser(_ user: String) throws {
        let source = try Source(user: user)
        if try !sources().contains(where: { $0.user == user }) { try saveSource(source) }
    }
    public func count(user: String? = nil) throws -> Int {
        let result = try user.map { try rows("SELECT count(*) FROM bookmarks WHERE user=?", [$0]) } ?? rows("SELECT count(*) FROM bookmarks")
        return Int(result.first?.first ?? "0") ?? 0
    }
    public func apply(_ bookmarks: [Bookmark], source: Source, full: Bool) throws {
        guard !readOnly, bookmarks.allSatisfy({ $0.user == source.user }) else { throw HatebuError("取り込み元が一致しません。") }
        try execute("BEGIN IMMEDIATE")
        do {
            try saveSource(source)
            if full { try run("DELETE FROM bookmarks WHERE user=?", [source.user]) }
            let sql = """
            INSERT INTO bookmarks(id,user,title,title_normalized,url,comment,tags,tag_text,date,host,search_text)
            VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,title_normalized=excluded.title_normalized,comment=excluded.comment,
            tags=excluded.tags,tag_text=excluded.tag_text,date=excluded.date,host=excluded.host,search_text=excluded.search_text
            WHERE bookmarks.title != excluded.title OR bookmarks.comment != excluded.comment
               OR bookmarks.tags != excluded.tags OR bookmarks.date != excluded.date
            """
            let statement = try prepare(sql, []); defer { sqlite3_finalize(statement) }
            for item in bookmarks {
                let tags = String(decoding: try JSONEncoder().encode(item.tags), as: UTF8.self)
                let values = [item.id,item.user,item.title,Text.normalized(item.title),item.url,item.comment,tags,
                              "\n" + item.tags.map(Text.normalized).joined(separator: "\n") + "\n",item.date,item.host.lowercased(),item.searchText]
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                for (index,value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index+1), value, -1, sqliteTransient) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private var columns: String { "id,user,title,url,comment,tags,date" }
    private func decode(_ row: [String]) throws -> Bookmark {
        var item = Bookmark(user: row[1], title: row[2], url: row[3], comment: row[4],
                            tags: try JSONDecoder().decode([String].self, from: Data(row[5].utf8)), date: row[6])
        item.id = row[0]; return item
    }
    public func get(_ ids: [String]) throws -> [Bookmark] {
        guard !ids.isEmpty else { return [] }
        var seen = Set<String>()
        let limited = Array(ids.filter { seen.insert($0).inserted }.prefix(200))
        let items = try rows("SELECT \(columns) FROM bookmarks WHERE id IN (\(limited.map { _ in "?" }.joined(separator: ",")))", limited).map(decode)
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id,$0) })
        return limited.compactMap { lookup[$0] }
    }
    public func search(_ input: String, user: String? = nil, limit: Int = 50) throws -> SearchResult {
        let started = Date(), query = try SearchQuery(input), size = max(1,min(limit,200))
        var conditions: [String] = [], values: [String] = []
        let indexed = query.terms.filter { $0.unicodeScalars.count >= 3 }
        if !indexed.isEmpty {
            conditions.append("rowid IN (SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH ?)")
            values.append(indexed.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        for term in query.terms { conditions.append("instr(search_text,?)>0"); values.append(term) }
        for tag in query.tags { conditions.append("instr(tag_text,?)>0"); values.append("\n" + tag + "\n") }
        if let site = query.site { conditions.append("(host=? OR substr(host,-length(?)-1)='.'||?)"); values += [site,site,site] }
        if let after = query.after { conditions.append("date>=?"); values.append(after) }
        if let before = query.before { conditions.append("date<?"); values.append(before) }
        if let user { conditions.append("user=?"); values.append(user) }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let rank = query.terms.map { _ in "CASE WHEN instr(title_normalized,?)>0 THEN 1 ELSE 0 END" }.joined(separator: "+")
        values += query.terms
        let order = rank.isEmpty ? "date DESC,id" : "(\(rank)) DESC,date DESC,id"
        let items = try rows("SELECT \(columns) FROM bookmarks\(whereClause) ORDER BY \(order) LIMIT \(size + 1)", values).map(decode)
        return SearchResult(query: input, items: Array(items.prefix(size)), elapsedMilliseconds: Date().timeIntervalSince(started)*1000, hasMore: items.count > size)
    }
}
