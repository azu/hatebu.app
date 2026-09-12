import SwiftUI
import HatebuCore

struct FaviconView: View {
    let site: FaviconSite?
    let cache: FaviconCache
    @State private var image: NSImage?
    @State private var loadedSite: FaviconSite?

    var body: some View {
        Group {
            if loadedSite == site, let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(Color.secondaryText)
            }
        }
        .frame(width: 20, height: 20)
        .frame(width: 32, height: 36)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: site) {
            image = nil; loadedSite = site
            guard let site else { return }
            let saved = await cache.cachedData(for: site)
            guard !Task.isCancelled else { return }
            image = saved.flatMap(NSImage.init(data:))
            let latest = await cache.data(for: site)
            guard !Task.isCancelled else { return }
            image = latest.flatMap(NSImage.init(data:))
        }
    }
}
