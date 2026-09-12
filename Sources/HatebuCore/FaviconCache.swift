import Foundation
import ImageIO

public struct FaviconSite: Hashable, Sendable {
    public let origin: URL
    public var cacheKey: String { Text.id(origin.absoluteString) }
    public var requestURL: URL {
        var components = URLComponents(string: "https://cdn-ak2.favicon.st-hatena.com/64")!
        components.queryItems = [URLQueryItem(name: "url", value: origin.absoluteString)]
        return components.url!
    }

    public init?(pageURL: URL?) {
        guard let pageURL, ["http", "https"].contains(pageURL.scheme?.lowercased()),
              let host = pageURL.host, !host.isEmpty else { return nil }
        // Reuse the icon across pages and send only the site's origin to Hatena.
        var components = URLComponents()
        components.scheme = "https"; components.host = host.lowercased(); components.path = "/"
        guard let origin = components.url else { return nil }
        self.origin = origin
    }
}

/// Icon downloads and disk reads run independently of bookmark search.
public actor FaviconCache {
    public typealias Fetcher = @Sendable (URL) async throws -> Data
    private struct Entry: Codable {
        var data: Data?
        var retryAfter: Date
    }
    private let paths: DataPaths
    private let fetcher: Fetcher
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private static let maximumBytes = 256 * 1024
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    public init(paths: DataPaths, fetcher: @escaping Fetcher = { @Sendable url in try await FaviconCache.fetch(url) }) {
        self.paths = paths; self.fetcher = fetcher
    }

    /// Returns the saved image even when it is due for refresh.
    public func cachedData(for site: FaviconSite) -> Data? { entry(for: site.cacheKey)?.data }

    public func data(for site: FaviconSite, now: Date = Date()) async -> Data? {
        let key = site.cacheKey
        let previous = entry(for: key)
        if let previous, now < previous.retryAfter { return previous.data }
        if let task = inFlight[key] { return await task.value }
        let task = Task(priority: .utility) { await refresh(site, previous: previous, now: now) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        return data
    }

    private func refresh(_ site: FaviconSite, previous: Entry?, now: Date) async -> Data? {
        let next: Entry
        do {
            let data = try await fetcher(site.requestURL)
            guard Self.isImage(data) else { throw HatebuError("Invalid favicon") }
            next = Entry(data: data, retryAfter: now.addingTimeInterval(7 * 24 * 60 * 60))
        } catch {
            // Keep a stale icon offline, and avoid retrying missing icons on each keystroke.
            next = Entry(data: previous?.data, retryAfter: now.addingTimeInterval(60 * 60))
        }
        remember(next, key: site.cacheKey)
        do {
            try paths.prepare()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file(site.cacheKey), options: .atomic)
        } catch { /* A disk cache failure must not prevent the image or results from appearing. */ }
        return next.data
    }

    private var directory: URL { paths.root.appendingPathComponent("favicons", isDirectory: true) }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
    private func entry(for key: String) -> Entry? {
        if let entry = entries[key] { return entry }
        guard let data = try? Data(contentsOf: file(key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.data.map(Self.isImage) ?? true else { return nil }
        remember(entry, key: key)
        return entry
    }
    private func remember(_ entry: Entry, key: String) {
        if entries[key] == nil, entries.count >= 256, let evicted = entries.keys.first {
            entries[evicted] = nil
        }
        entries[key] = entry
    }

    private static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...512).contains(width), (1...512).contains(height) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    public static func fetch(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true,
              http.expectedContentLength <= maximumBytes else { throw HatebuError("Favicon unavailable") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw HatebuError("Favicon too large") }
            data.append(byte)
        }
        return data
    }
}
