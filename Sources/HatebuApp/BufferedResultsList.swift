import SwiftUI
import HatebuCore

struct ResultRowLayout {
    static let height: CGFloat = 160
    let count: Int
    var contentHeight: CGFloat { CGFloat(count) * Self.height }

    func rows(at offset: CGFloat, viewportHeight: CGFloat) -> Range<Int> {
        guard count > 0, viewportHeight > 0 else { return 0..<0 }
        let top = min(max(0, offset), max(0, contentHeight - viewportHeight))
        // One viewport on either side keeps incoming rows ready during momentum scrolling.
        let first = max(0, Int(floor((top - viewportHeight) / Self.height)))
        let end = min(count, Int(ceil((top + 2 * viewportHeight) / Self.height)))
        return first..<max(first, end)
    }
}

/// Every row has a lightweight, fixed-height anchor. Only nearby rows build their content.
struct BufferedResultsList<Content: View>: View {
    let items: [Bookmark]
    let selectedID: String?
    let resetKey: [String]
    let onKey: (SearchKeyAction) -> Void
    let content: (Bookmark, @escaping () -> Void) -> Content
    @Namespace private var scrollSpace
    @FocusState private var focused: Bool
    @State private var renderedRows: Range<Int>?

    var body: some View {
        GeometryReader { viewport in
            let layout = ResultRowLayout(count: items.count)
            let remembered = renderedRows?.clamped(to: 0..<items.count)
            let rows = (remembered?.isEmpty == false ? remembered : nil)
                ?? layout.rows(at: 0, viewportHeight: viewport.size.height)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ZStack(alignment: .topLeading) {
                                if rows.contains(index) {
                                    content(item) { focused = true }
                                        .background(selectedID == item.id ? Color.bookmarkGreen.opacity(0.18) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .accessibilityElement(children: .contain)
                                        .accessibilityAddTraits(selectedID == item.id ? [.isSelected] : [])
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: ResultRowLayout.height, alignment: .top)
                            .id(item.id)
                        }
                    }
                    .frame(height: layout.contentHeight, alignment: .top)
                    .onGeometryChange(for: Range<Int>.self) { geometry in
                        layout.rows(at: -geometry.frame(in: .named(scrollSpace)).minY,
                                    viewportHeight: viewport.size.height)
                    } action: { rows in
                        // This value changes at row boundaries, not for every scroll pixel.
                        renderedRows = rows
                    }
                }
                .coordinateSpace(name: scrollSpace)
                .focusable().focused($focused).focusEffectDisabled()
                .accessibilityLabel("検索結果")
                .onKeyPress(.downArrow) { onKey(.next); return .handled }
                .onKeyPress(.upArrow) { onKey(.previous); return .handled }
                .onKeyPress(.return) { onKey(.open); return .handled }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: resetKey) {
                    renderedRows = nil
                    if let first = items.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }
}
