import XCTest
@testable import HatebuCore

final class FaviconTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!

    func testSiteSharesIconsWithoutSendingPageDetails() throws {
        let site = try XCTUnwrap(FaviconSite(pageURL: URL(string: "http://name:password@EXAMPLE.com:8080/article?q=private#section")))
        XCTAssertEqual(site.origin.absoluteString, "https://example.com/")
        XCTAssertEqual(site, FaviconSite(pageURL: URL(string: "https://example.com/another")))
        let request = try XCTUnwrap(URLComponents(url: site.requestURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.host, "cdn-ak2.favicon.st-hatena.com")
        XCTAssertEqual(request.path, "/64")
        XCTAssertEqual(request.queryItems, [URLQueryItem(name: "url", value: "https://example.com/")])
        XCTAssertNil(FaviconSite(pageURL: URL(string: "file:///tmp/page.html")))
        XCTAssertNil(FaviconSite(pageURL: URL(string: "javascript:alert(1)")))
        XCTAssertNil(FaviconSite(pageURL: nil))
    }

    func testConcurrentRowsAndRelaunchReuseOneDownload() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let site = try XCTUnwrap(FaviconSite(pageURL: URL(string: "https://example.com/one")))
        let counter = Calls(), png = png
        let cache = FaviconCache(paths: paths) { _ in
            await counter.add()
            try await Task.sleep(for: .milliseconds(30))
            return png
        }
        let images = await withTaskGroup(of: Data?.self, returning: [Data?].self) { group in
            for _ in 0..<12 { group.addTask { await cache.data(for: site) } }
            var result: [Data?] = []
            for await image in group { result.append(image) }
            return result
        }
        XCTAssertEqual(images, Array(repeating: png, count: 12))
        let calls = await counter.value
        XCTAssertEqual(calls, 1)

        let reopened = FaviconCache(paths: paths) { _ in
            await counter.add()
            throw URLError(.notConnectedToInternet)
        }
        let saved = await reopened.cachedData(for: site)
        let fresh = await reopened.data(for: site)
        XCTAssertEqual(saved, png)
        XCTAssertEqual(fresh, png)
        let callsAfterReopen = await counter.value
        XCTAssertEqual(callsAfterReopen, 1, "Relaunching must reuse the saved icon without downloading")
    }

    func testStaleImageSurvivesOfflineRefreshAndRetriesLater() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let site = try XCTUnwrap(FaviconSite(pageURL: URL(string: "https://example.com")))
        let png = png, start = Date(timeIntervalSince1970: 1_000_000)
        let initial = FaviconCache(paths: paths) { _ in png }
        let original = await initial.data(for: site, now: start)
        XCTAssertEqual(original, png)

        let counter = Calls()
        let offline = FaviconCache(paths: paths) { _ in
            await counter.add()
            throw URLError(.notConnectedToInternet)
        }
        let later = start.addingTimeInterval(8 * 24 * 60 * 60)
        let stale = await offline.cachedData(for: site)
        XCTAssertEqual(stale, png, "Saved images remain available before refresh starts")
        let failed = await offline.data(for: site, now: later)
        XCTAssertEqual(failed, png)
        _ = await offline.data(for: site, now: later.addingTimeInterval(10))
        let callsBeforeRetry = await counter.value
        XCTAssertEqual(callsBeforeRetry, 1)

        let recovered = FaviconCache(paths: paths) { _ in await counter.add(); return png }
        _ = await recovered.data(for: site, now: later.addingTimeInterval(20))
        let callsAfterReopen = await counter.value
        XCTAssertEqual(callsAfterReopen, 1, "The retry delay must survive relaunch")
        let refreshed = await recovered.data(for: site, now: later.addingTimeInterval(3601))
        XCTAssertEqual(refreshed, png)
        let callsAfterRetry = await counter.value
        XCTAssertEqual(callsAfterRetry, 2)
    }

    func testInvalidImageIsNotShownAndFailureIsCached() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let site = try XCTUnwrap(FaviconSite(pageURL: URL(string: "https://example.com")))
        let counter = Calls(), now = Date()
        let cache = FaviconCache(paths: paths) { _ in
            await counter.add()
            return Data("<html>unavailable</html>".utf8)
        }
        let first = await cache.data(for: site, now: now)
        let again = await cache.data(for: site, now: now.addingTimeInterval(1))
        XCTAssertNil(first)
        XCTAssertNil(again)
        let calls = await counter.value
        XCTAssertEqual(calls, 1)
        let reopened = FaviconCache(paths: paths) { _ in await counter.add(); return Data() }
        let afterReopen = await reopened.data(for: site, now: now.addingTimeInterval(2))
        XCTAssertNil(afterReopen)
        let callsAfterReopen = await counter.value
        XCTAssertEqual(callsAfterReopen, 1)
    }

    private func temporaryPaths() -> DataPaths {
        DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hatebu-favicon-" + UUID().uuidString).path)
    }
}

private actor Calls {
    private(set) var value = 0
    func add() { value += 1 }
}
