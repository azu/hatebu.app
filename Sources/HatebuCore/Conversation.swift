import Foundation

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var role: String
    public var text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

public struct Conversation: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var threadID: String?
    public var query: String
    public var bookmarkIDs: [String]
    public var messages: [ChatMessage] = []
    public var activities: [SearchActivity]? = []
    public var lastRun: SearchRun?
    public var updatedAt: Date = Date()
    public init(query: String = "", bookmarkIDs: [String] = []) { self.query = query; self.bookmarkIDs = bookmarkIDs }
    public var title: String { messages.first(where: { $0.role == "user" })?.text ?? (query.isEmpty ? "新しい検索" : query) }
}

public struct SearchRun: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, completed, failed, stopped, interrupted }
    public var id: UUID
    public var state: State
    public var startedAt: Date?
    public var finishedAt: Date?
    public var candidateCount: Int
    public init(id: UUID = UUID(), state: State = .running, startedAt: Date? = Date(), finishedAt: Date? = nil, candidateCount: Int = 0) {
        self.id = id; self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt; self.candidateCount = candidateCount
    }
}

/// User-facing facts from tool events, never the model's private reasoning.
public struct SearchActivity: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, completed, failed, stopped, unconfirmed }
    public var id: String
    public var title: String
    public var state: State
    public var toolName: String?
    public var command: String?
    public var query: String?
    public var detail: String?
    public init(id: String, title: String, state: State, toolName: String? = nil, command: String? = nil, query: String? = nil, detail: String? = nil) {
        self.id = id; self.title = title; self.state = state
        self.toolName = toolName; self.command = command; self.query = query; self.detail = detail
    }
    public var stateLabel: String {
        switch state {
        case .running: return "実行中"
        case .completed: return "完了"
        case .failed: return "失敗"
        case .stopped: return "停止"
        case .unconfirmed: return "結果未確認"
        }
    }
    public mutating func settle(as state: State) {
        guard self.state == .running else { return }
        self.state = state
        if title.contains("調べています") || title == "検索中" { title = "保存済みのブックマークを検索" }
        if state == .unconfirmed { detail = "この操作の終了通知は届きませんでした。回答の完了状態とは別に表示しています。" }
    }
}

public struct ConversationStore {
    public let paths: DataPaths
    public init(paths: DataPaths) { self.paths = paths }
    public func save(_ conversation: Conversation) throws {
        try paths.prepare()
        try FileManager.default.createDirectory(at: paths.conversations, withIntermediateDirectories: true)
        let file = paths.conversations.appendingPathComponent(conversation.id.uuidString + ".json")
        try JSONEncoder().encode(conversation).write(to: file, options: .atomic)
    }
    public func list() throws -> [Conversation] {
        guard FileManager.default.fileExists(atPath: paths.conversations.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.conversations, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

public struct AIAnswer: Codable, Equatable, Sendable {
    public var message: String
    public var bookmarkIDs: [String]
    public init(message: String, bookmarkIDs: [String]) { self.message = message; self.bookmarkIDs = bookmarkIDs }
}

public enum CodexEvent: Equatable, Sendable {
    case thread(String), progress(String), activity(SearchActivity), candidateIDs([String]), answer(AIAnswer), failure(String), completed
}

/// Buffers bytes, not decoded strings: pipes may split either a line or a UTF-8 scalar.
public struct CodexEventParser {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) -> [CodexEvent] {
        buffer.append(bytes)
        var events: [CodexEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            events += Self.parse(line)
        }
        return events
    }
    public mutating func finish() -> [CodexEvent] {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? [] : Self.parse(buffer)
    }
    private static func parse(_ data: Data) -> [CodexEvent] {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = event["type"] as? String else { return [] }
        if type == "thread.started", let id = event["thread_id"] as? String { return [.thread(id)] }
        if type == "turn.started" { return [.progress("検索の手がかりを確認しています…")] }
        if type == "turn.completed" { return [.completed] }
        if type == "turn.failed" || type == "error" {
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String ?? "Codex の実行に失敗しました。"
            return [.failure(message)]
        }
        guard let item = event["item"] as? [String: Any], let itemType = item["type"] as? String else { return [] }
        if ["command_execution", "mcp_tool_call", "web_search"].contains(itemType),
           ["item.started", "item.updated", "item.completed"].contains(type) {
            let id = item["id"] as? String ?? "command"
            let status = item["status"] as? String
            let hasError = item["error"].map { !($0 is NSNull) } ?? false
            let failed = status == "failed" || status == "declined" || (item["exit_code"] as? Int).map { $0 != 0 } == true || hasError
            let completed = status != "in_progress" && (type == "item.completed" || status == "completed")
            let state: SearchActivity.State = failed ? .failed : (completed ? .completed : .running)
            let command = item["command"] as? String
            let presentation = command.map { ToolPresentation(command: $0) }
            var activity = SearchActivity(id: id, title: presentation?.title ?? "保存済みのブックマークを検索", state: state,
                                          toolName: presentation?.name, command: command, query: presentation?.query)
            var output: Any? = item["aggregated_output"]
            if itemType == "mcp_tool_call" {
                let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
                activity.toolName = name.isEmpty ? "MCP ツール" : name
                activity.title = "ツールを実行"
                output = item["result"]
                if (item["result"] as? [String: Any])?["isError"] as? Bool == true { activity.state = .failed }
            } else if itemType == "web_search" {
                activity.toolName = "web_search"
                activity.query = item["query"] as? String
                activity.title = activity.query.map { "「\($0)」を Web 検索" } ?? "Web を検索"
            }
            if failed || activity.state == .failed {
                activity.detail = (item["error"] as? [String: Any])?["message"] as? String
                    ?? (item["exit_code"] as? Int).map { "終了コード: \($0)" }
                    ?? "ツールを実行できませんでした。"
                return [.activity(activity)]
            }
            if let result: SearchResult = decodeOutput(output) {
                activity.query = result.query
                activity.title = "\(result.query.isEmpty ? "最近のブックマーク" : "「\(result.query)」") · \(result.items.count)\(result.hasMore ? "+" : "") 件"
                return [.activity(activity), .candidateIDs(result.items.map(\.id)), .progress("見つかった候補を確認しています…")]
            }
            if let items: [Bookmark] = decodeOutput(output) {
                activity.title = "候補 \(items.count) 件の詳細を確認"
                return [.activity(activity), .candidateIDs(items.map(\.id))]
            }
            return [.activity(activity), .progress(completed ? "回答をまとめています…" : activity.title + "…")]
        }
        if itemType == "agent_message", type == "item.completed", let text = item["text"] as? String {
            if let answer = try? JSONDecoder().decode(AIAnswer.self, from: Data(text.utf8)) { return [.answer(answer)] }
            return [.progress(text)]
        }
        return []
    }
    private static func decodeOutput<T: Decodable>(_ value: Any?, depth: Int = 0) -> T? {
        guard let value, depth < 5 else { return nil }
        if let text = value as? String {
            let data = Data(text.utf8)
            if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
            if let wrapped = try? JSONSerialization.jsonObject(with: data) { return decodeOutput(wrapped, depth: depth + 1) }
        } else if let object = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: object), let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
            for key in ["output", "structured_content", "structuredContent", "content", "text"] {
                if let decoded: T = decodeOutput(object[key], depth: depth + 1) { return decoded }
            }
        } else if let blocks = value as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: blocks), let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
            for block in blocks { if let decoded: T = decodeOutput(block, depth: depth + 1) { return decoded } }
        }
        return nil
    }

}
