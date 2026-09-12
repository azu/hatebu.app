import SwiftUI
import HatebuCore

@MainActor final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selectedID = nil; resultMode = "search"; scheduleSearch() } } }
    @Published var selectedUser: String? { didSet { if selectedUser != oldValue { selectedID = nil; scheduleSearch() } } }
    @Published var items: [Bookmark] = []
    @Published var aiItems: [Bookmark] = [] { didSet { if resultMode == "ai" { clearMissingSelection() } } }
    @Published var resultMode = "search" { didSet { if resultMode != oldValue { selectedID = nil } } }
    @Published var selectedID: String?
    @Published var reference: Bookmark?
    @Published var status = CacheStatus(count: 0, sources: [], syncing: false)
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var elapsed: Double = 0
    @Published var hasMore = false
    @Published var showSettings = false
    @Published var sidebarVisible = true
    @Published var draft = ""
    @Published var conversation = Conversation()
    @Published var history: [Conversation] = []
    @Published var isThinking = false
    @Published var isStopping = false
    @Published var progress = ""
    @Published var aiError: String?
    @Published var notice: String?
    let paths: DataPaths
    let favicons: FaviconCache
    private let configuredCLI: String?
    private let configuredCodex: String?
    private let openURL: (URL) -> Void
    var cliPath: String { configuredCLI ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("hatebu").path }
    var visibleItems: [Bookmark] { resultMode == "ai" ? aiItems : items }
    var selected: Bookmark? { visibleItems.first { $0.id == selectedID } }
    private var generation = SearchGeneration()
    private var searchTask: Task<Void, Never>?
    private var runner: CodexRunner?
    private var runID: UUID?
    private var pendingQuestion: String?
    private var receivedCandidates = false
    private var revision = ""
    private var requestedSyncAt: Date = .distantPast

    init(paths: DataPaths? = nil, cli: String? = nil, codex: String? = nil, openURL: ((URL) -> Void)? = nil) {
        self.paths = paths ?? DataPaths(directory: Self.dataDirectoryArgument)
        self.favicons = FaviconCache(paths: self.paths)
        self.configuredCLI = cli; self.configuredCodex = codex
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        history = (try? ConversationStore(paths: self.paths).list()) ?? []
    }

    private static var dataDirectoryArgument: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--data-dir"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    func scheduleSearch() {
        let ticket = generation.next(), input = query, user = selectedUser, paths = paths
        searchTask?.cancel(); isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(35))
                let result = try await Task.detached(priority: .userInitiated) { try Cache.search(input, paths: paths, user: user, limit: 100) }.value
                guard !Task.isCancelled, generation.accepts(ticket) else { return }
                items = result.items; elapsed = result.elapsedMilliseconds; hasMore = result.hasMore
                searchError = nil; isSearching = false
                clearMissingSelection()
            } catch is CancellationError { }
            catch {
                guard generation.accepts(ticket) else { return }
                searchError = error.localizedDescription; isSearching = false
                // Keep the previous results while an incomplete query is being typed.
            }
        }
    }

    func monitor() async {
        scheduleSearch()
        while !Task.isCancelled {
            await refreshStatus()
            try? await Task.sleep(for: .seconds(2))
        }
    }
    func refreshStatus() async {
        do {
            let paths = paths
            let next = try await Task.detached { try Cache.status(paths: paths) }.value
            let key = next.sources.map { "\($0.user):\($0.lastSuccess ?? 0)" }.joined(separator: ",")
            status = next
            if revision != key { revision = key; scheduleSearch() }
            if next.needsRefresh && !next.syncing && Date().timeIntervalSince(requestedSyncAt) > 10 { synchronize() }
        } catch { notice = error.localizedDescription }
    }
    func synchronize(full: Bool = false, force: Bool = false) {
        guard !status.syncing else { return }
        requestedSyncAt = Date()
        if BackgroundSync.start(paths: paths, executable: cliPath, full: full, force: force) { status.syncing = true; notice = nil }
        else { notice = "同期 CLI を起動できません。アプリをビルドし直してください。" }
    }
    func addUser(_ name: String) async throws {
        let paths = paths
        try await Task.detached {
            let db = try BookmarkDatabase(paths: paths)
            try db.addUser(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        await refreshStatus()
    }
    func open(_ item: Bookmark) { if let url = item.webURL { openURL(url) } }
    func openSelected() { if let selected { open(selected) } }
    func moveSelection(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let current = visibleItems.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + offset, 0), visibleItems.count - 1) } ?? 0
        selectedID = visibleItems[next].id
    }
    private func clearMissingSelection() {
        if !visibleItems.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }
    var highlightTerms: [String] {
        var queries = [query]
        if resultMode == "ai", let run = conversation.lastRun {
            queries += (conversation.activities ?? []).filter { $0.id.hasPrefix(run.id.uuidString + ":") }.compactMap(\.query)
        }
        return Array(Set(queries.flatMap { input -> [String] in
            guard let query = try? SearchQuery(input) else { return [] }
            return query.terms + query.tags + (query.site.map { [$0] } ?? [])
        }))
    }
    private var currentToolIssues: [SearchActivity] {
        guard let run = conversation.lastRun else { return [] }
        let activities = conversation.activities ?? []
        // Older histories did not prefix item IDs with a turn ID.
        let scoped = activities.contains { $0.id.contains(":") }
        return activities.filter {
            (!scoped || $0.id.hasPrefix(run.id.uuidString + ":")) && [.failed, .unconfirmed].contains($0.state)
        }
    }
    var hasToolIssues: Bool { !currentToolIssues.isEmpty }
    var runTitle: String {
        if isStopping { return "検索を停止中" }
        if isThinking { return "検索中" }
        switch conversation.lastRun?.state {
        case .completed: return "\(hasToolIssues ? "回答完了" : "検索完了") · \(conversation.lastRun?.candidateCount ?? 0) 件の候補"
        case .failed: return "検索を完了できませんでした"
        case .stopped: return "検索を停止しました"
        case .interrupted, .running: return "前回の検索は中断されています"
        case nil: return ""
        }
    }
    var runHint: String {
        if isThinking { return progress }
        switch conversation.lastRun?.state {
        case .completed:
            if hasToolIssues {
                let unconfirmed = currentToolIssues.filter { $0.state == .unconfirmed }.count
                let failed = currentToolIssues.filter { $0.state == .failed }.count
                let details = [unconfirmed > 0 ? "\(unconfirmed) 回が結果未確認" : nil,
                               failed > 0 ? "\(failed) 回が失敗" : nil].compactMap { $0 }.joined(separator: "、")
                return "検索ツールの \(details)です。候補は確認でき、条件を追加して再検索できます。"
            }
            return "候補を開くか、条件を追加して続けられます。"
        case .failed, .stopped, .interrupted, .running: return "見つかった候補は残っています。条件を変えて続けられます。"
        case nil: return ""
        }
    }

    func copy(_ item: Bookmark) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url, forType: .string) }
    func useReference(_ item: Bookmark) { reference = item; if draft.isEmpty { draft = "この候補に近い記事を探したい。" } }
    func exclude(_ item: Bookmark) { draft = "「\(item.title)」（ID: \(item.id)）は探している記事と違います。他の候補を探してください。" }

    func receive(_ url: URL) {
        guard let handoff = Handoff(url: url) else { return }
        query = handoff.query
        if let id = handoff.bookmarkID { reference = try? BookmarkDatabase(paths: paths, readOnly: true).get([id]).first }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .focusSearch, object: nil)
    }
    func newConversation() {
        guard !isThinking else { return }
        progress = ""; conversation = Conversation(query: query); aiItems = []; reference = nil; draft = ""; aiError = nil; resultMode = "search"
    }
    func restore(_ value: Conversation) {
        guard !isThinking else { return }
        progress = ""; conversation = value; selectedID = nil
        if conversation.lastRun == nil, conversation.messages.last?.role == "assistant" {
            conversation.lastRun = SearchRun(state: .completed, startedAt: nil, finishedAt: value.updatedAt, candidateCount: value.bookmarkIDs.count)
        } else if conversation.lastRun?.state == .running {
            conversation.lastRun?.state = .interrupted
        } else if conversation.lastRun == nil, !conversation.messages.isEmpty {
            conversation.lastRun = SearchRun(state: .interrupted, startedAt: nil)
        }
        // Previous versions mislabeled missing tool completion events as failures.
        conversation.activities = (conversation.activities ?? []).map {
            var activity = $0
            if activity.state == .failed && activity.title == "保存済みのブックマークを調べています" && activity.toolName == nil {
                activity.state = .running; activity.settle(as: .unconfirmed)
            }
            return activity
        }
        finishActivities(as: conversation.lastRun?.state == .completed ? .unconfirmed : .stopped)
        query = value.query; reference = nil; draft = ""; aiError = nil
        aiItems = (try? BookmarkDatabase(paths: paths, readOnly: true).get(value.bookmarkIDs)) ?? []
        resultMode = "ai"
    }
    private func saveConversation() {
        conversation.updatedAt = Date()
        do {
            let store = ConversationStore(paths: paths); try store.save(conversation); history = try store.list()
        } catch { notice = "会話を保存できません: \(error.localizedDescription)" }
    }
    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        let configured = configuredCodex ?? UserDefaults.standard.string(forKey: "codexPath") ?? ""
        guard let executable = configured.isEmpty ? CodexRunner.findExecutable() : configured else {
            aiError = "Codex が見つかりません。設定で実行ファイルを選び、ターミナルで codex login を実行してください。"; return
        }
        conversation.query = query
        if let reference, !conversation.bookmarkIDs.contains(reference.id) { conversation.bookmarkIDs.append(reference.id) }
        conversation.messages.append(ChatMessage(role: "user", text: question))
        let id = UUID(); runID = id
        conversation.lastRun = SearchRun(id: id)
        saveConversation(); draft = ""; isThinking = true; isStopping = false; receivedCandidates = false; aiError = nil; progress = "Codex を起動しています…"
        let runner = CodexRunner(); self.runner = runner
        let request = CodexRequest(executable: executable, searchCLI: cliPath, paths: paths, conversation: conversation,
                                   question: question, candidates: items + (reference.map { [$0] } ?? []))
        runner.start(request, onEvent: { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.runID == id else { return }
                switch event {
                case .thread(let thread): self.conversation.threadID = thread; self.saveConversation()
                case .progress(let text): if !self.isStopping { self.progress = text }
                case .activity(var activity):
                    // Item IDs are only unique within a Codex turn.
                    activity.id = id.uuidString + ":" + activity.id
                    var activities = self.conversation.activities ?? []
                    if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                        activity.toolName = activity.toolName ?? activities[index].toolName
                        activity.command = activity.command ?? activities[index].command
                        activity.query = activity.query ?? activities[index].query
                        if activity.title == "保存済みのブックマークを検索", let previousQuery = activity.query { activity.title = "「\(previousQuery)」を検索" }
                        activities[index] = activity
                    }
                    else { activities.append(activity) }
                    self.conversation.activities = activities
                    self.saveConversation()
                case .candidateIDs(let ids):
                    let known = Set(self.aiItems.map(\.id))
                    let newItems = (try? BookmarkDatabase(paths: self.paths, readOnly: true).get(ids.filter { !known.contains($0) })) ?? []
                    self.aiItems = Array((self.aiItems + newItems).prefix(100))
                    self.conversation.bookmarkIDs = self.aiItems.map(\.id)
                    if !self.receivedCandidates { self.resultMode = "ai"; self.receivedCandidates = true }
                    self.saveConversation()
                case .answer: if !self.isStopping { self.progress = "回答を受け取りました…" }
                case .completed: if !self.isStopping { self.progress = "検索結果を確定しています…" }
                default: break
                }
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.runID == id else { return }
                let stopped = self.isStopping
                self.isThinking = false; self.isStopping = false; self.runner = nil; self.runID = nil
                self.progress = stopped ? "停止しました。見つかった候補を残しています。" : ""
                self.conversation.lastRun?.finishedAt = Date()
                switch result {
                case .success(let answer):
                    self.finishActivities(as: .unconfirmed)
                    self.conversation.lastRun?.state = .completed
                    self.resultMode = "ai"
                    self.aiItems = (try? BookmarkDatabase(paths: self.paths, readOnly: true).get(answer.bookmarkIDs)) ?? []
                    self.selectedID = nil
                    self.conversation.bookmarkIDs = self.aiItems.map(\.id)
                    self.conversation.lastRun?.candidateCount = self.aiItems.count
                    self.conversation.messages.append(ChatMessage(role: "assistant", text: answer.message))
                    self.saveConversation()
                case .failure(let error):
                    let cancelled = error is CancellationError
                    self.finishActivities(as: cancelled ? .stopped : .unconfirmed)
                    self.conversation.lastRun?.state = cancelled ? .stopped : .failed
                    self.conversation.lastRun?.candidateCount = self.aiItems.count
                    if !cancelled { self.aiError = error.localizedDescription }
                }
                self.saveConversation()
                if let next = self.pendingQuestion {
                    self.pendingQuestion = nil; self.draft = next; self.send()
                }
            }
        })
    }
    private func finishActivities(as state: SearchActivity.State) {
        conversation.activities = (conversation.activities ?? []).map {
            var activity = $0
            activity.settle(as: state)
            return activity
        }
    }
    func stop() {
        guard isThinking, !isStopping else { return }
        isStopping = true; progress = "検索を停止しています…"
        runner?.cancel()
    }
    func shutdown() {
        pendingQuestion = nil
        finishActivities(as: .stopped)
        if isThinking {
            conversation.lastRun?.state = .stopped; conversation.lastRun?.finishedAt = Date()
            saveConversation()
        }
        runner?.cancel(force: true)
    }
    func revise() {
        guard isThinking, !isStopping, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingQuestion = draft; draft = ""; stop()
    }
    func retry() {
        guard !isThinking, let last = conversation.messages.last(where: { $0.role == "user" }) else { return }
        draft = last.text
    }
}
