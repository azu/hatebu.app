import Foundation

struct ToolPresentation {
    var name: String
    var title: String
    var query: String?

    init(command: String) {
        var tokens = Self.words(command)
        if tokens.count >= 3, ["sh", "bash", "zsh"].contains(URL(fileURLWithPath: tokens[0]).lastPathComponent), tokens[1].hasPrefix("-"), tokens[1].contains("c") {
            tokens = Self.words(tokens[2])
        }
        name = tokens.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "コマンド"
        title = "コマンドを実行"
        guard let executable = tokens.firstIndex(where: { URL(fileURLWithPath: $0).lastPathComponent == "hatebu" }) else { return }
        let valued = Set(["--data-dir", "--format", "--limit", "--user"])
        var positional: [String] = [], index = executable + 1
        while index < tokens.count {
            if tokens[index] == "--" { positional += tokens.dropFirst(index + 1); break }
            if valued.contains(tokens[index]) { index += 2; continue }
            if !tokens[index].hasPrefix("--") { positional.append(tokens[index]) }
            index += 1
        }
        guard let action = positional.first else { name = "hatebu"; return }
        name = "hatebu " + action
        if action == "search" {
            query = positional.dropFirst().joined(separator: " ")
            title = query!.isEmpty ? "最近のブックマークを検索" : "「\(query!)」を検索"
        } else if action == "show" { title = "候補の詳細を確認" }
    }

    // Presentation only: never evaluate a shell string or expand substitutions.
    private static func words(_ input: String) -> [String] {
        var result: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for character in input {
            if escaped { word.append(character); escaped = false; started = true }
            else if character == "\\", quote != "'" { escaped = true; started = true }
            else if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        if escaped { word.append("\\") }
        if started { result.append(word) }
        return result
    }
}
