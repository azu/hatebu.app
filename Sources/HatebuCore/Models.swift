import Foundation
import CryptoKit

public struct HatebuError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Text {
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }
    public static func id(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    public static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var user: String
    public var title: String
    public var url: String
    public var comment: String
    public var tags: [String]
    public var date: String
    public var host: String { URL(string: url)?.host ?? "" }
    public var webURL: URL? {
        guard let value = URL(string: url), ["http", "https"].contains(value.scheme?.lowercased()),
              let host = value.host, !host.isEmpty else { return nil }
        return value
    }
    public var searchText: String { Text.normalized([title, url, comment, tags.joined(separator: " ")].joined(separator: "\n")) }

    public init(user: String, title: String, url: String, comment: String, tags: [String], date: String) {
        self.id = Text.id(user + "\n" + url)
        self.user = user; self.title = title; self.url = url
        self.comment = comment; self.tags = tags; self.date = date
    }
}

public struct Source: Codable, Identifiable, Equatable, Sendable {
    public var id: String { user }
    public var user: String
    public var lastAttempt: Double?
    public var lastSuccess: Double?
    public var lastFullSync: Double?
    public var cursor: Double?
    public var error: String?
    public var retryAfter: Double?
    public init(user: String) throws {
        guard user.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{1,31}$", options: .regularExpression) != nil else {
            throw HatebuError("はてなユーザー名を入力してください（英数字・ハイフン・アンダースコア）。")
        }
        self.user = user
    }
    public func isDue(now: Date = Date(), interval: Double = 900) -> Bool {
        if let retryAfter, now.timeIntervalSince1970 < retryAfter { return false }
        if let attempt = lastAttempt, error != nil, now.timeIntervalSince1970 - attempt < 60 { return false }
        return now.timeIntervalSince1970 - (lastSuccess ?? 0) >= interval
    }
}

public struct CacheStatus: Codable, Sendable {
    public var count: Int
    public var sources: [Source]
    public var syncing: Bool
    public var needsRefresh: Bool { sources.contains { $0.isDue() } }
    public init(count: Int, sources: [Source], syncing: Bool) { self.count = count; self.sources = sources; self.syncing = syncing }
}

public struct SearchResult: Codable, Sendable {
    public var query: String
    public var items: [Bookmark]
    public var elapsedMilliseconds: Double
    public var hasMore: Bool
}

public struct DataPaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("bookmarks.sqlite") }
    public var lock: URL { root.appendingPathComponent("sync.lock") }
    public var conversations: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    public init(directory: String? = nil) {
        let value = directory ?? ProcessInfo.processInfo.environment["HATEBU_DATA_DIR"]
        if let value, !value.isEmpty {
            root = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HatebuSearch", isDirectory: true)
        }
    }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

public struct SearchQuery: Equatable, Sendable {
    public var terms: [String] = []
    public var tags: [String] = []
    public var site: String?
    public var after: String?
    public var before: String?

    public init(_ input: String) throws {
        var pieces: [String] = [], word = "", quoted = false
        for c in input.precomposedStringWithCompatibilityMapping {
            if c == "\"" { quoted.toggle() }
            else if c.isWhitespace && !quoted {
                if !word.isEmpty { pieces.append(word); word = "" }
            } else { word.append(c) }
        }
        // Unclosed quotes remain searchable while the user is typing.
        if !word.isEmpty { pieces.append(word) }
        for piece in pieces {
            let value = Text.normalized(piece)
            if value.hasPrefix("tag:"), value.count > 4 { tags.append(String(value.dropFirst(4))) }
            else if value.hasPrefix("site:"), value.count > 5 { site = String(value.dropFirst(5)) }
            else if value.hasPrefix("after:"), value.count > 6 { after = try Self.validateDate(String(value.dropFirst(6))) }
            else if value.hasPrefix("before:"), value.count > 7 { before = try Self.validateDate(String(value.dropFirst(7))) }
            else { terms.append(value) }
        }
    }
    private static func validateDate(_ value: String) throws -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw HatebuError("日付は YYYY-MM-DD で指定してください。")
        }
        return value
    }
}

/// A ticket belongs to one search input. An older response may never replace a newer one.
public struct SearchGeneration: Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    @discardableResult public mutating func next() -> UInt64 { value &+= 1; return value }
    public func accepts(_ ticket: UInt64) -> Bool { ticket == value }
}
