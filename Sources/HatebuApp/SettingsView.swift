import SwiftUI
import HatebuCore

struct SettingsView: View {
    @ObservedObject var model: SearchModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("codexPath") private var codexPath = ""
    @State private var user = ""
    @State private var working = false
    @State private var error: String?
    @State private var periodic = SyncSchedule.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Hatebu Search の設定").font(.title2.weight(.semibold)); Spacer(); Button("完了") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(24)
            Divider()
            Form {
                Section {
                    HStack {
                        TextField("はてなユーザー名",text: $user).onSubmit { addUser() }
                        Button("追加して取り込む") { addUser() }.disabled(working || user.isEmpty)
                    }
                    ForEach(model.status.sources) { source in
                        HStack {
                            Label(source.user,systemImage: "person.crop.circle")
                            Spacer()
                            if source.lastSuccess == nil { Text("取り込み待ち").foregroundStyle(.secondary) }
                            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bookmarkGreen) }
                        }
                    }
                } header: { Text("公開はてなブックマーク") } footer: {
                    Text("公開データだけを取得します。検索欄へ入力すると保存済みの結果をすぐに表示し、古いデータは裏で更新します。")
                }
                Section {
                    Toggle("アプリを閉じても 15 分ごとに更新",isOn: Binding(get: { periodic }, set: { new in
                            working = true
                            let cli = model.cliPath, paths = model.paths
                            Task {
                                do { try await Task.detached { try SyncSchedule.setEnabled(new,cli: cli,paths: paths) }.value; periodic = new; error = nil }
                                catch { self.error = error.localizedDescription }
                                working = false
                            }
                        })).disabled(working)
                    Button("全件を照合して、削除も反映する") { model.synchronize(full: true) }.disabled(model.status.sources.isEmpty || model.status.syncing)
                } header: { Text("データの更新") } footer: {
                    Text("通常は差分を取得し、7 日ごとに全件を照合します。定期更新を使わなくても、Alfred やアプリで検索すると必要に応じて更新します。")
                }
                Section {
                    HStack {
                        TextField(CodexRunner.findExecutable() ?? "Codex 実行ファイルのパス",text: $codexPath).font(.system(.body,design: .monospaced))
                        Button("選択…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                            if panel.runModal() == .OK { codexPath = panel.url?.path ?? "" }
                        }
                    }
                } header: { Text("Codex") } footer: {
                    Text("既存の Codex ログインを使います。未ログインの場合はターミナルで codex login を実行してください。入力した内容と候補のタイトル・URL・コメントを Codex に送信し、このアプリ内で会話を続けます。")
                }
                Section {
                    HStack {
                        Button("Alfred Workflow を開く") {
                            if let url = Bundle.main.url(forResource: "HatebuSearch",withExtension: "alfredworkflow") { NSWorkspace.shared.open(url) }
                            else { error = "Workflow が見つかりません。scripts/build.sh でアプリを作成してください。" }
                        }
                        Spacer()
                        Button("データの保存先を開く") {
                            do { try model.paths.prepare(); NSWorkspace.shared.open(model.paths.root) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                } header: { Text("Alfred と保存先") } footer: {
                    Text("Alfred とアプリは同じキャッシュを使います。Workflow のキーワードは hb です。")
                }
                if let error { Label(error,systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            }.formStyle(.grouped)
        }.frame(width: 650,height: 650).tint(.bookmarkGreen)
    }
    private func addUser() {
        guard !working, !user.isEmpty else { return }
        working = true
        Task {
            do { try await model.addUser(user); user = ""; error = nil }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

enum SyncSchedule {
    private static let label = "info.azu.hatebusearch.sync"
    private static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: file.path) }
    static func setEnabled(_ enabled: Bool,cli: String,paths: DataPaths) throws {
        let domain = "gui/\(getuid())"
        if isEnabled { _ = try launchctl(["bootout", domain + "/" + label]) }
        if !enabled { if isEnabled { try FileManager.default.removeItem(at: file) }; return }
        let job: [String: Any] = ["Label": label, "ProgramArguments": [cli,"sync","--if-stale","--data-dir",paths.root.path],
                                   "RunAtLoad": true,"StartInterval": 900,"ProcessType": "Background","LowPriorityIO": true]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: job,format: .xml,options: 0).write(to: file,options: .atomic)
        let result = try launchctl(["bootstrap",domain,file.path])
        guard result == 0 else { try? FileManager.default.removeItem(at: file); throw HatebuError("定期更新を登録できませんでした（launchctl \(result)）。") }
    }
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
}
