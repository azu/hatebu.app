import SwiftUI
import HatebuCore

@main struct HatebuSearchApp: App {
    @NSApplicationDelegateAdaptor(HatebuApplicationDelegate.self) private var appDelegate
    @StateObject private var model = SearchModel()
    var body: some Scene {
        WindowGroup("Hatebu Search") {
            SearchView(model: model)
                .frame(minWidth: 1040, minHeight: 650)
                .tint(.bookmarkGreen)
                .task { await model.monitor() }
                .onOpenURL { model.receive($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
                .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        }
        .defaultSize(width: 1260, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("新しい検索の会話") { model.newConversation() }.keyboardShortcut("n").disabled(model.isThinking)
                Button(model.sidebarVisible ? "サイドバーを隠す" : "サイドバーを表示") { model.sidebarVisible.toggle() }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("検索欄へ移動") { NotificationCenter.default.post(name: .focusSearch, object: nil) }.keyboardShortcut("f")
                Button("ブックマークを更新") { model.synchronize(force: true) }.keyboardShortcut("r")
            }
        }
    }
}

final class HatebuApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .focusSearch, object: nil)
        return true
    }
}

extension Notification.Name { static let focusSearch = Notification.Name("HatebuFocusSearch") }
extension Color {
    // Filled buttons keep a dark background for their white labels. Text and
    // icons use a brighter green on dark surfaces instead of that same fill.
    static let bookmarkGreen = Color(red: 0.13, green: 0.42, blue: 0.35)
    static let bookmarkAccent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.44, green: 0.82, blue: 0.70, alpha: 1)
        }
        return NSColor(srgbRed: 0.13, green: 0.42, blue: 0.35, alpha: 1)
    })
    static let secondaryText = Color.primary.opacity(0.82)
}
