import SwiftUI
import HatebuCore

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @State private var focusRequest = 0
    @State private var toolsExpanded = true

    var body: some View {
        HSplitView {
            if model.sidebarVisible { sidebar.frame(minWidth: 170, idealWidth: 190, maxWidth: 240) }
            results.frame(minWidth: 430, maxWidth: .infinity)
            conversation.frame(minWidth: 330, idealWidth: 370, maxWidth: 500)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(model.sidebarVisible ? "サイドバーを隠す（⌥⌘S）" : "サイドバーを表示（⌥⌘S）")
                    .accessibilityLabel("サイドバーの表示を切り替え")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.synchronize(force: true) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("公開ブックマークを更新（⌘R）").disabled(model.status.syncing || model.status.sources.isEmpty)
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.help("設定")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focusRequest += 1 }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIBRARY").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(Color.secondaryText).padding(.top, 26).padding(.horizontal, 18)
            Button { model.selectedUser = nil } label: {
                HStack { Label("すべてのブックマーク", systemImage: "tray.full"); Spacer(); Text(model.status.count.formatted()).font(.caption.monospacedDigit()) }
                    .padding(10).background(model.selectedUser == nil ? Color.bookmarkGreen.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 10)
            ForEach(model.status.sources) { source in
                Button { model.selectedUser = source.user } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle").foregroundStyle(Color.secondaryText)
                        Text(source.user).lineLimit(1)
                        Spacer()
                        if source.error != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    }.padding(10).background(model.selectedUser == source.user ? Color.bookmarkGreen.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.horizontal, 8)
            }
            Button { model.showSettings = true } label: { Label("ユーザーを追加", systemImage: "plus").font(.caption).foregroundStyle(Color.secondaryText) }
                .buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 10)
            HStack { Text("RECENT SEARCHES").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(1.5); Spacer(); Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("新しい会話").disabled(model.isThinking) }
                .foregroundStyle(Color.secondaryText).padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.history.isEmpty { Text("会話しながら探した履歴が\nここに残ります。").font(.caption).foregroundStyle(Color.secondaryText).lineSpacing(5).padding(.horizontal, 18) }
                    ForEach(model.history) { value in
                        Button { model.restore(value) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bubble.left").padding(.top, 2).foregroundStyle(Color.secondaryText)
                                Text(value.title).lineLimit(2).multilineTextAlignment(.leading).font(.system(size: 12))
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.conversation.id == value.id ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).padding(.horizontal, 8).disabled(model.isThinking)
                    }
                }
            }
            Spacer(minLength: 0)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(model.status.syncing ? .orange : Color.bookmarkGreen).frame(width: 6,height: 6)
                    Text(model.status.syncing ? "バックグラウンドで更新中" : "この Mac に保存済み").font(.caption)
                }
                if let last = model.status.sources.compactMap(\.lastSuccess).min() {
                    Text("更新 \(Date(timeIntervalSince1970: last).formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }.padding(18)
        }
        .frame(maxHeight: .infinity).background(.regularMaterial)
    }

    private var results: some View {
        VStack(spacing: 0) {
            let terms = model.highlightTerms
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(Color.bookmarkAccent)
                    SearchField(text: $model.query, focusRequest: focusRequest, allowsFocus: !model.showSettings) { action in
                        switch action {
                        case .previous: model.moveSelection(by: -1)
                        case .next: model.moveSelection(by: 1)
                        case .open: model.openSelected()
                        }
                    }.frame(maxWidth: .infinity).frame(height: 28)
                    if model.isSearching { ProgressView().controlSize(.small) }
                    else if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondaryText) }.buttonStyle(.plain) }
                }
                Text("タイトル・コメント・タグを検索  /  tag:  site:  after:  before:").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                HStack {
                    Picker("結果", selection: $model.resultMode) {
                        Text("検索結果").tag("search")
                        Text("AI の候補\(model.aiItems.isEmpty ? "" : " · \(model.aiItems.count)")").tag("ai")
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                    Spacer()
                    Text("\(model.visibleItems.count)\(model.hasMore && model.resultMode == "search" ? "+" : "") 件").font(.caption.monospacedDigit()).foregroundStyle(Color.secondaryText)
                }
            }.padding(24).background(Color(nsColor: .textBackgroundColor))
            Divider()
            if model.visibleItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: model.status.sources.isEmpty ? "bookmark.circle" : "text.magnifyingglass").font(.system(size: 45,weight: .ultraLight)).foregroundStyle(Color.bookmarkGreen.opacity(0.7))
                    Text(model.status.sources.isEmpty ? "あの記事を、もう一度。" : (model.resultMode == "ai" ? (model.isThinking ? "候補を探しています" : "AI の候補はまだありません") : (model.status.syncing ? "ブックマークを取り込んでいます" : "一致する記事は見つかりませんでした"))).font(.title3.weight(.medium))
                    Text(model.status.sources.isEmpty ? "はてなユーザー名を登録して、\n公開ブックマークをこの Mac で検索できます。" : "別の言葉で検索するか、右の会話欄に\n覚えている内容を入力してください。")
                        .font(.callout).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center).lineSpacing(5)
                    if model.status.sources.isEmpty { Button("はてなユーザーを登録") { model.showSettings = true }.buttonStyle(.borderedProminent).controlSize(.large) }
                    if model.status.syncing { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedID) {
                        ForEach(model.visibleItems) { item in
                            BookmarkRow(item: item, terms: terms)
                                .tag(item.id).id(item.id)
                                .listRowSeparator(.hidden)
                                .padding(.vertical, 3)
                                .onTapGesture(count: 2) { if let url = item.webURL { NSWorkspace.shared.open(url) } }
                                .contextMenu {
                                    Button("ページを開く") { if let url = item.webURL { NSWorkspace.shared.open(url) } }.disabled(item.webURL == nil)
                                    Button("URL をコピー") { model.copy(item) }
                                    Divider()
                                    Button("この候補に近い記事を探す") { model.useReference(item) }
                                    Button("この候補を除いて探す") { model.exclude(item) }
                                }
                        }
                    }.listStyle(.plain).padding(.horizontal, 10)
                        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                        .onKeyPress(.return) { model.openSelected(); return .handled }
                        .onChange(of: model.selectedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                }
            }
            if !model.visibleItems.isEmpty {
                Divider()
                HStack {
                    Button { model.openSelected() } label: { Label("開く",systemImage: "arrow.up.right") }.disabled(model.selected?.webURL == nil)
                    Button { if let selected = model.selected { model.copy(selected) } } label: { Image(systemName: "doc.on.doc") }
                        .help("URL をコピー").disabled(model.selected == nil)
                    Text(model.selected == nil ? "↓ 先頭を選択  ↵ 開く" : "↑↓ 選択  ↵ 開く").foregroundStyle(Color.secondaryText)
                    Spacer()
                    Button { if let selected = model.selected { model.useReference(selected) } } label: { Label("これに近い記事",systemImage: "sparkle.magnifyingglass") }
                        .disabled(model.selected == nil)
                }.buttonStyle(.borderless).tint(.bookmarkAccent).font(.caption).padding(.horizontal, 24).padding(.vertical, 13)
            }
            Divider()
            HStack(spacing: 6) {
                if model.status.syncing { ProgressView().controlSize(.mini); Text("保存済みの結果を表示 · 裏で更新しています") }
                else if let error = model.searchError ?? model.notice ?? model.status.sources.compactMap(\.error).first { Image(systemName: "exclamationmark.circle"); Text(error).lineLimit(2) }
                else { Image(systemName: "internaldrive"); Text("ローカル検索"); Spacer(); Text(String(format: "%.0f ms",model.elapsed)).monospacedDigit() }
            }.font(.system(size: 11)).foregroundStyle(Color.secondaryText).padding(.horizontal, 24).padding(.vertical, 10)
        }.background(Color(nsColor: .textBackgroundColor))
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles").foregroundStyle(Color.bookmarkAccent)
                Text("一緒に探す").font(.headline)
                Text("Codex").font(.system(size: 11,weight: .medium)).foregroundStyle(Color.secondaryText).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary,in: Capsule())
                Spacer()
                Button { model.newConversation() } label: { Image(systemName: "plus.bubble") }.buttonStyle(.plain).help("新しい会話").disabled(model.isThinking)
            }.padding(22)
            Divider()
            if !model.runTitle.isEmpty { runStatus }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.conversation.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("言葉が出てこなくても。") .font(.system(size: 21,weight: .medium))
                                Text("いつ読んだか、どんな内容だったか。\n覚えていることを手がかりに、\n保存した記事から一緒に探します。")
                                    .font(.callout).foregroundStyle(Color.secondaryText).lineSpacing(6)
                                suggestion("去年読んだ、日本語の解説だったと思う")
                                suggestion("このテーマの入門記事を探したい")
                            }.padding(.top, 20)
                        }
                        ForEach(model.conversation.messages) { message in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(message.role == "user" ? "あなた" : "Codex").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondaryText)
                                Text(message.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading)
                            }.padding(14).background(message.role == "user" ? Color.bookmarkGreen.opacity(0.07) : Color.primary.opacity(0.025),in: RoundedRectangle(cornerRadius: 12))
                                .id(message.id)
                        }
                        if let activities = model.conversation.activities, !activities.isEmpty {
                            DisclosureGroup("使ったツール · \(activities.count) 回", isExpanded: $toolsExpanded) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(activities) { ToolActivityRow(activity: $0) }
                                }.padding(.top, 12)
                            }.font(.caption).foregroundStyle(Color.secondaryText)
                        }
                        if let error = model.aiError {
                            Label(error,systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            Button("条件を編集して再試行") { model.retry() }.font(.caption)
                            Button("新しい会話で探す") { model.newConversation() }.font(.caption)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }.onChange(of: model.conversation.messages.count) { _,_ in withAnimation { proxy.scrollTo("bottom",anchor: .bottom) } }
            }
            Spacer(minLength: 0)
            if let reference = model.reference {
                HStack(spacing: 7) {
                    Image(systemName: "paperclip")
                    Text(reference.title).lineLimit(1)
                    Button { model.reference = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.caption).foregroundStyle(Color.secondaryText).padding(10).background(Color.bookmarkGreen.opacity(0.06),in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 18).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField("覚えていることを入力…",text: $model.draft,axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.plain).font(.system(size: 13)).padding(.top, 3)
                    .disabled(model.isStopping)
                HStack {
                    Text("保存済みのブックマークから検索").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    Spacer()
                    if model.isThinking {
                        if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("この条件で探し直す") { model.revise() }.disabled(model.isStopping)
                                .help("実行中の検索を停止して、同じ会話でこの条件を送信します")
                        }
                        Button { model.stop() } label: { Image(systemName: "stop.fill") }.help("検索を停止").disabled(model.isStopping)
                    } else {
                        Button { model.send() } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers: .command)
                            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.status.sources.isEmpty).help("送信（⌘Enter）")
                    }
                }
            }.padding(13).background(Color(nsColor: .textBackgroundColor),in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1),lineWidth: 1)).padding(16)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var runStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if model.isThinking { ProgressView().controlSize(.small) }
                    else { Image(systemName: runIcon).foregroundStyle(model.conversation.lastRun?.state == .failed ? Color.orange : Color.bookmarkAccent) }
                    Text(model.runTitle).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 5)
                    if let run = model.conversation.lastRun, let start = run.startedAt, model.isThinking || run.finishedAt != nil {
                        let seconds = Int(max(0, (run.finishedAt ?? context.date).timeIntervalSince(start)))
                        Text(seconds < 60 ? "\(seconds)秒" : "\(seconds / 60)分\(seconds % 60)秒")
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.secondaryText)
                    }
                }
                Text(model.runHint).font(.caption).foregroundStyle(Color.secondaryText).lineLimit(3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bookmarkGreen.opacity(0.07))
        }
        .accessibilityElement(children: .combine)
    }
    private var runIcon: String {
        switch model.conversation.lastRun?.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .stopped, .interrupted, .running: return "stop.circle"
        case nil: return "circle"
        }
    }
    private func suggestion(_ text: String) -> some View {
        Button { model.draft = text } label: {
            HStack(alignment: .top) { Text(text).multilineTextAlignment(.leading); Spacer(minLength: 5); Image(systemName: "arrow.up.left") }
                .font(.caption).foregroundStyle(Color.secondaryText).padding(11).frame(maxWidth: .infinity,alignment: .leading)
                .background(.primary.opacity(0.035),in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

private struct BookmarkRow: View {
    let item: Bookmark
    let terms: [String]
    var body: some View {
        HStack(alignment: .top,spacing: 12) {
            Text(String(item.host.prefix(1)).uppercased()).font(.system(size: 14,weight: .semibold,design: .rounded))
                .foregroundStyle(Color.bookmarkAccent).frame(width: 32,height: 36).background(Color.bookmarkGreen.opacity(0.08),in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading,spacing: 7) {
                HighlightedText(text: item.title, terms: terms).font(.system(size: 15,weight: .medium)).lineLimit(2).fixedSize(horizontal: false,vertical: true)
                HStack(spacing: 6) { HighlightedText(text: item.host, terms: terms).lineLimit(1); Text("·"); Text(String(item.date.prefix(10))) }.font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                if !item.comment.isEmpty { HighlightedText(text: item.comment, terms: terms).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(2).lineSpacing(3) }
                if !item.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(item.tags.prefix(4).enumerated()),id: \.offset) { _,tag in
                            HighlightedText(text: tag, terms: terms).font(.system(size: 11)).lineLimit(1).padding(.horizontal,6).padding(.vertical,3).background(.primary.opacity(0.05),in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 12).padding(.horizontal, 5)
    }
}

private struct HighlightedText: View {
    let text: String
    let terms: [String]
    var body: some View { Text(highlighted) }
    private var highlighted: AttributedString {
        var value = AttributedString(text)
        for match in SearchHighlight.ranges(in: text, terms: terms) {
            if let original = Range(match, in: text), let range = Range(original, in: value) {
                value[range].backgroundColor = Color.yellow.opacity(0.28)
                value[range].foregroundColor = Color.primary
            }
        }
        return value
    }
}

private struct ToolActivityRow: View {
    let activity: SearchActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                if activity.state == .running { ProgressView().controlSize(.mini) }
                else { Image(systemName: icon).foregroundStyle(activity.state == .failed ? Color.orange : Color.secondaryText) }
                Text(activity.toolName ?? "検索操作").fontWeight(.medium)
                Spacer(minLength: 4)
                Text(activity.stateLabel).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
            }
            Text(activity.title).textSelection(.enabled).foregroundStyle(.primary)
            if let detail = activity.detail { Text(detail).font(.system(size: 11)).textSelection(.enabled) }
            if let command = activity.command, !command.isEmpty {
                DisclosureGroup("実行コマンド") {
                    Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                }.font(.system(size: 11))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var icon: String {
        switch activity.state {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .stopped: return "stop.circle"
        case .unconfirmed: return "minus.circle"
        }
    }
}
