import Foundation
import Darwin

public enum HatenaParser {
    public static func parse(_ text: String, user: String) throws -> [Bookmark] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard lines.count % 4 == 0 else { throw HatebuError("はてなの応答形式が不正です。保存済みのデータを維持しました。") }
        let count = lines.count / 4
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyyMMddHHmmss"; formatter.isLenient = false
        let isoFormatter = ISO8601DateFormatter()
        let tagPattern = try NSRegularExpression(pattern: "\\[([^\\[\\]]+)\\]")
        var items: [Bookmark] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            let title = lines[i*3], comment = lines[i*3+1], address = lines[i*3+2]
            let metadata = lines[count*3+i].split(separator: "\t", omittingEmptySubsequences: false)
            // Historical bookmarks can contain about:, javascript:, or malformed HTTP hosts.
            // Keep their metadata searchable; only Bookmark.webURL may be opened by the UI.
            guard address.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil,
                  metadata.count >= 2, metadata[1].count == 14,
                  let date = formatter.date(from: String(metadata[1])), formatter.string(from: date) == metadata[1] else {
                throw HatebuError("はてなの応答に不正な URL または日時があります（\(i+1) 件目）。")
            }
            let tags = tagPattern.matches(in: comment, range: NSRange(comment.startIndex..., in: comment)).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: comment) else { return nil }
                return String(comment[range])
            }
            items.append(Bookmark(user: user, title: title.isEmpty ? address : title, url: address, comment: comment, tags: tags, date: isoFormatter.string(from: date)))
        }
        return items
    }
}

public final class SyncLock {
    private var descriptor: Int32
    public init(paths: DataPaths) throws {
        try paths.prepare()
        descriptor = Darwin.open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HatebuError("同期ロックを開けません。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw HatebuError("別のプロセスが同期中です。")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
    public static func isLocked(paths: DataPaths) -> Bool {
        let fd = Darwin.open(paths.lock.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN); return false
    }
}

public struct SyncReport: Codable, Sendable {
    public var user: String
    public var fetched: Int
    public var total: Int
    public var full: Bool
    public var error: String?
}

public struct Synchronizer: Sendable {
    public let paths: DataPaths
    private let fetcher: @Sendable (String, Date?) async throws -> [Bookmark]
    public init(paths: DataPaths) {
        self.paths = paths; self.fetcher = { try await Synchronizer.fetchAll(user: $0, since: $1) }
    }
    public init(paths: DataPaths, fetcher: @escaping @Sendable (String, Date?) async throws -> String) {
        self.paths = paths; self.fetcher = { user, date in try HatenaParser.parse(await fetcher(user, date), user: user) }
    }

    public func sync(user: String? = nil, ifStale: Bool = false, full: Bool = false) async throws -> [SyncReport] {
        let lock = try SyncLock(paths: paths)
        defer { withExtendedLifetime(lock) {} }
        let db = try BookmarkDatabase(paths: paths)
        let sources = try db.sources().filter { user == nil || $0.user == user }
        if let user, sources.isEmpty { throw HatebuError("\(user) は未登録です。先に source add を実行してください。") }
        var reports: [SyncReport] = []
        for var source in sources {
            if ifStale && !full && !source.isDue() { continue }
            let started = Date()
            let isFull = full || source.lastFullSync == nil || started.timeIntervalSince1970 - (source.lastFullSync ?? 0) >= 604800
            source.lastAttempt = started.timeIntervalSince1970
            source.error = nil
            try db.saveSource(source)
            let previous = source
            do {
                let bookmarks = try await fetcher(source.user, isFull ? nil : source.cursor.map { Date(timeIntervalSince1970: $0 - 120) })
                source.lastSuccess = Date().timeIntervalSince1970
                source.cursor = started.timeIntervalSince1970
                source.retryAfter = nil
                if isFull { source.lastFullSync = source.lastSuccess }
                try db.apply(bookmarks, source: source, full: isFull)
                reports.append(SyncReport(user: source.user, fetched: bookmarks.count, total: try db.count(user: source.user), full: isFull))
            } catch {
                // A transaction failure must not advance any success metadata.
                source = previous
                source.error = error.localizedDescription
                source.retryAfter = Date().timeIntervalSince1970 + 60
                try db.saveSource(source)
                reports.append(SyncReport(user: source.user, fetched: 0, total: try db.count(user: source.user), full: isFull, error: source.error))
            }
        }
        return reports
    }

    public static func fetchAll(user: String, since: Date?, pageSize: Int = 5_000,
                                pageFetcher: @Sendable (String, Date?, Int, Int) async throws -> String = { try await fetchPage(user: $0, since: $1, offset: $2, limit: $3) }) async throws -> [Bookmark] {
        guard pageSize > 0 else { throw HatebuError("取得件数が不正です。") }
        var bookmarks: [Bookmark] = [], known = Set<String>(), offset = 0
        while true {
            try Task.checkCancellation()
            let text = try await pageFetcher(user, since, offset, pageSize)
            let page: [Bookmark]
            do { page = try HatenaParser.parse(text, user: user) }
            catch { throw HatebuError("\(error.localizedDescription) 取得位置: \(offset)") }
            let added = page.filter { known.insert($0.id).inserted }
            // Do not silently accept a server that stopped honoring pagination.
            if page.count >= pageSize && added.isEmpty { throw HatebuError("はてなの続きのデータを取得できません。保存済みのデータを維持しました。") }
            bookmarks += added
            if page.count < pageSize { return bookmarks }
            // A small overlap tolerates entries added/removed while pages are fetched.
            offset += page.count - min(100, pageSize / 10)
        }
    }

    public static func fetchPage(user: String, since: Date?, offset: Int, limit: Int) async throws -> String {
        _ = try Source(user: user)
        var components = URLComponents(string: "https://b.hatena.ne.jp/\(user)/search.data")!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let since {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
            formatter.dateFormat = "yyyyMMddHHmmss"
            components.queryItems?.append(URLQueryItem(name: "timestamp", value: formatter.string(from: since)))
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: components.url!)
        request.setValue("HatebuSearch/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "b.hatena.ne.jp", http.url?.path == components.path else {
            throw HatebuError("公開ブックマークを取得できません（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw HatebuError("取得データを UTF-8 として読めません。") }
        return text
    }
}

public enum Cache {
    public static func status(paths: DataPaths) throws -> CacheStatus {
        guard FileManager.default.fileExists(atPath: paths.database.path) else {
            return CacheStatus(count: 0, sources: [], syncing: SyncLock.isLocked(paths: paths))
        }
        let db = try BookmarkDatabase(paths: paths, readOnly: true)
        return CacheStatus(count: try db.count(), sources: try db.sources(), syncing: SyncLock.isLocked(paths: paths))
    }
    public static func search(_ query: String, paths: DataPaths, user: String? = nil, limit: Int = 50) throws -> SearchResult {
        guard FileManager.default.fileExists(atPath: paths.database.path) else {
            return SearchResult(query: query, items: [], elapsedMilliseconds: 0, hasMore: false)
        }
        return try BookmarkDatabase(paths: paths, readOnly: true).search(query, user: user, limit: limit)
    }
}
