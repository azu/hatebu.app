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
            ["title": message, "subtitle": "検索条件を確認してください。保存済みのデータは維持しています。", "valid": false,
             "mods": ["alt": ["valid": false]]],
            ["title": "アプリで続きを探す", "arg": Handoff(query: query).url.absoluteString, "valid": true,
             "mods": ["alt": ["valid": false]]]
        ]])
    }
    public static func output(result: SearchResult, status: CacheStatus) throws -> Data {
        let suffix = status.syncing || status.needsRefresh ? " · 保存済みの結果を表示／更新中" : ""
        var items: [[String: Any]] = result.items.map { item in
            let body = commentBody(item)
            let metadata = "\(item.host) · \(item.date.prefix(10))"
            let summary = body.isEmpty ? "コメントなし · \(metadata)" : "\(oneLine(body)) · \(metadata)"
            let handoff = Handoff(query: result.query, bookmarkID: item.id).url.absoluteString
            return ["title": item.title, "subtitle": summary + suffix,
             "arg": item.url, "valid": item.webURL != nil,
             "text": ["copy": item.url],
             "mods": ["cmd": ["valid": true, "arg": handoff,
                                "subtitle": "この候補を参考に、アプリで続きを探す"],
                      "alt": ["valid": item.webURL != nil, "arg": detail(item, body: body),
                              "subtitle": "コメント全文を表示 · \(metadata)",
                              "variables": ["bookmark_url": item.url, "bookmark_handoff": handoff]]]]
        }
        if status.sources.isEmpty {
            items.append(["title": "はてなユーザーを設定する", "subtitle": "アプリで公開ブックマークを取り込みます", "arg": Handoff(query: result.query).url.absoluteString,
                          "mods": ["alt": ["valid": false]]])
        } else {
            let errors = status.sources.compactMap(\.error)
            let subtitle = errors.first.map { "更新できませんでした。保存済みデータで検索できます: \($0)" }
                ?? (status.syncing || status.needsRefresh ? "保存済みの結果を表示しています。裏でデータを更新中です" : "検索語と候補を引き継いで、Codex と会話できます")
            items.append(["title": "アプリで続きを探す", "subtitle": subtitle, "arg": Handoff(query: result.query).url.absoluteString,
                          "mods": ["alt": ["valid": false]]])
        }
        var response: [String: Any] = ["items": items]
        if status.syncing || status.needsRefresh { response["rerun"] = 1.0 }
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }

    // Hatena stores tags at the start of the comment. Only hide that prefix in
    // the presentation; bracketed text elsewhere remains part of the comment.
    private static func commentBody(_ item: Bookmark) -> String {
        var body = item.comment.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        while body.first == "[", let end = body.firstIndex(of: "]"),
              item.tags.contains(String(body[body.index(after: body.startIndex)..<end])) {
            body = body[body.index(after: end)...].drop(while: \.isWhitespace)
        }
        return String(body)
    }

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func detail(_ item: Bookmark, body: String) -> String {
        let metadata = [
            "**タグ**　\(markdown(item.tags.isEmpty ? "なし" : item.tags.joined(separator: " · ")))",
            "**登録日**　\(markdown(String(item.date.prefix(10))))",
            "**ユーザー**　\(markdown(item.user))",
            "**URL**　\(markdown(item.url))"
        ].joined(separator: "  \n")
        return """
        # \(markdown(oneLine(item.title)))

        \(markdown(body.isEmpty ? "コメントなし" : body))

        ---

        \(metadata)
        """
    }

    private static func markdown(_ value: String) -> String {
        // Stored text is plain text, not Markdown. Escape ASCII punctuation so
        // links, images, HTML and formatting in comments cannot become markup.
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.map { character in
            if character == "\n" { return "  \n" }
            let punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
            return punctuation.contains(character) ? "\\" + String(character) : String(character)
        }.joined()
    }
}
