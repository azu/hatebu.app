import Foundation
import HatebuCore
import CBackground

@main struct HatebuCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static let help = """
    Hatebu Search — 公開ブックマークをローカル検索

    hatebu source add <はてなユーザー名>
    hatebu source list
    hatebu sync [--if-stale] [--full] [--user NAME]
    hatebu search "検索語 tag:タグ site:ドメイン after:YYYY-MM-DD" [--format json|alfred|text] [--limit 50]
    hatebu show <bookmark-id> [--format json|text]
    hatebu status
    hatebu alfred "検索語"    キャッシュで検索し、必要なら裏で同期

    共通: --data-dir PATH（または HATEBU_DATA_DIR）
    search / show はネットワーク取得や DB 更新を行いません。
    """

    static func run(_ args: [String]) async throws {
        if args.first == "__codex", args.count >= 2 {
            let command = args[1]
            var pointers = args.dropFirst().map { strdup($0) } + [nil]
            defer { pointers.forEach { free($0) } }
            _ = pointers.withUnsafeMutableBufferPointer { hatebu_exec_isolated(command, $0.baseAddress!) }
            throw HatebuError("Codex を起動できませんでした（errno \(errno)）。")
        }
        if args.isEmpty || args.prefix(while: { $0 != "--" }).contains("--help") || args == ["help"] { print(help); return }
        var positional: [String] = [], options: [String: String] = [:], flags = Set<String>(), index = 0
        let valued = Set(["--data-dir", "--format", "--limit", "--user"])
        while index < args.count {
            let arg = args[index]
            if arg == "--" { positional += args.dropFirst(index+1); break }
            if valued.contains(arg) {
                guard index+1 < args.count else { throw HatebuError("\(arg) の値がありません。") }
                options[arg] = args[index+1]; index += 2
            } else if ["--if-stale", "--full"].contains(arg) { flags.insert(arg); index += 1 }
            else if arg.hasPrefix("--") { throw HatebuError("未対応のオプション: \(arg)") }
            else { positional.append(arg); index += 1 }
        }
        guard let command = positional.first else { print(help); return }
        let paths = DataPaths(directory: options["--data-dir"]), format = options["--format"] ?? "json"
        guard ["json", "alfred", "text"].contains(format) else { throw HatebuError("--format は json / alfred / text から選んでください。") }
        switch command {
        case "source":
            if positional.count == 3, positional[1] == "add" {
                let db = try BookmarkDatabase(paths: paths)
                try db.addUser(positional[2]); try json(db.sources())
            } else if positional.count == 2, positional[1] == "list" { try json(Cache.status(paths: paths).sources) }
            else { throw HatebuError("source add <ユーザー名> または source list を指定してください。") }
        case "sync":
            let reports = try await Synchronizer(paths: paths).sync(user: options["--user"], ifStale: flags.contains("--if-stale"), full: flags.contains("--full"))
            try json(reports)
            if reports.contains(where: { $0.error != nil }) { exit(1) }
        case "search", "alfred":
            let query = positional.dropFirst().joined(separator: " ")
            guard let limit = Int(options["--limit"] ?? "50"), (1...200).contains(limit) else { throw HatebuError("--limit は 1〜200 を指定してください。") }
            do {
                let result = try Cache.search(query, paths: paths, user: options["--user"], limit: limit)
                let status = try Cache.status(paths: paths)
                if command == "alfred", status.needsRefresh, !status.syncing {
                    BackgroundSync.start(paths: paths, executable: CommandLine.arguments[0])
                }
                if command == "alfred" || format == "alfred" { write(try Alfred.output(result: result, status: status)) }
                else if format == "text" { result.items.forEach { print("\($0.id)\t\($0.title)\n\($0.url)\n\($0.comment)\n") } }
                else { try json(result) }
            } catch {
                if command == "alfred" || format == "alfred" { write(try Alfred.failure(error.localizedDescription, query: query)) }
                else { throw error }
            }
        case "show":
            guard positional.count >= 2 else { throw HatebuError("bookmark ID を指定してください。") }
            let items = try BookmarkDatabase(paths: paths, readOnly: true).get(Array(positional.dropFirst()))
            if format == "text" { items.forEach { print("\($0.title)\n\($0.url)\n\($0.comment)") } }
            else { try json(items) }
        case "status": try json(Cache.status(paths: paths))
        default: throw HatebuError("未対応のコマンド: \(command)\n\(help)")
        }
    }
    static func json<T: Encodable>(_ value: T) throws { write(try JSONEncoder().encode(value)) }
    static func write(_ data: Data) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
}
