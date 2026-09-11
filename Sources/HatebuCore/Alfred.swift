import Foundation

public struct Handoff: Equatable, Sendable {
    public var query: String
    public var bookmarkID: String?
    public init(query: String, bookmarkID: String? = nil) { self.query = query; self.bookmarkID = bookmarkID }
    public var url: URL {
        var components = URLComponents()
        components.scheme = "hatebusearch"; components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if let bookmarkID { components.queryItems?.append(URLQueryItem(name: "id", value: bookmarkID)) }
        return components.url!
    }
    public init?(url: URL) {
        guard url.scheme == "hatebusearch", url.host == "search", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        query = components.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        bookmarkID = components.queryItems?.first(where: { $0.name == "id" })?.value
    }
}

public enum Alfred {
    public static func failure(_ message: String, query: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["items": [
            ["title": message, "subtitle": "検索条件を確認してください。保存済みのデータは維持しています。", "valid": false],
            ["title": "アプリで続きを探す", "arg": Handoff(query: query).url.absoluteString, "valid": true]
        ]])
    }
    public static func output(result: SearchResult, status: CacheStatus) throws -> Data {
        let suffix = status.syncing || status.needsRefresh ? " · 保存済みの結果を表示／更新中" : ""
        var items: [[String: Any]] = result.items.map { item in
            ["title": item.title, "subtitle": "\(item.host) · \(item.date.prefix(10)) · \(item.comment)\(suffix)",
             "arg": item.url, "valid": item.webURL != nil,
             "text": ["copy": item.url],
             "mods": ["cmd": ["valid": true, "arg": Handoff(query: result.query, bookmarkID: item.id).url.absoluteString,
                                "subtitle": "この候補を参考に、アプリで続きを探す"]]]
        }
        if status.sources.isEmpty {
            items.append(["title": "はてなユーザーを設定する", "subtitle": "アプリで公開ブックマークを取り込みます", "arg": Handoff(query: result.query).url.absoluteString])
        } else {
            let errors = status.sources.compactMap(\.error)
            let subtitle = errors.first.map { "更新できませんでした。保存済みデータで検索できます: \($0)" }
                ?? (status.syncing || status.needsRefresh ? "保存済みの結果を表示しています。裏でデータを更新中です" : "検索語と候補を引き継いで、Codex と会話できます")
            items.append(["title": "アプリで続きを探す", "subtitle": subtitle, "arg": Handoff(query: result.query).url.absoluteString])
        }
        var response: [String: Any] = ["items": items]
        if status.syncing || status.needsRefresh { response["rerun"] = 1.0 }
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }
}
