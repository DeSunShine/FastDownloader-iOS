import XCTest
@testable import FastDownloader

final class FastDownloaderTests: XCTestCase {
    func testFilenameSanitization() {
        XCTAssertEqual(
            FilenameResolver.sanitize("game:part/one?.zip"),
            "game_part_one_.zip"
        )
    }

    func testDownloadItemRoundTrip() throws {
        let original = DownloadItem(
            sourceURL: "https://example.com/file.bin",
            sourcePage: "https://example.com",
            filename: "file.bin",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .paused,
            receivedBytes: 1024,
            expectedBytes: 4096,
            requestHeaders: ["Referer": "https://example.com"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DownloadItem.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.progress, 0.25, accuracy: 0.0001)
    }

    func testURLResolutionAddsHTTPS() {
        XCTAssertEqual(
            BrowserStore.resolvedURL(from: "example.com")?.absoluteString,
            "https://example.com"
        )
    }

    func testURLResolutionPreservesHTTPS() {
        XCTAssertEqual(
            BrowserStore.resolvedURL(from: "https://example.com/test")?.absoluteString,
            "https://example.com/test"
        )
    }

    func testDownloadTestURLResolution() {
        XCTAssertEqual(
            BrowserStore.resolvedURL(from: "fsn1-speed.hetzner.com/100MB.bin")?.absoluteString,
            "https://fsn1-speed.hetzner.com/100MB.bin"
        )
    }

    func testSelectingTabChangesCurrentTab() {
        let store = BrowserStore()
        let first = store.addTab(select: true)
        let second = store.addTab(select: false)

        XCTAssertEqual(store.currentTab?.id, first.id)

        store.select(second.id)

        XCTAssertEqual(store.selectedTabID, second.id)
        XCTAssertEqual(store.currentTab?.id, second.id)
    }

    func testClosingSelectedTabSelectsRemainingTab() {
        let store = BrowserStore()
        let first = store.addTab(select: true)
        let second = store.addTab(select: true)

        XCTAssertEqual(store.currentTab?.id, second.id)

        store.close(second.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.currentTab?.id, first.id)
    }

    func testMovingTabChangesOrderWithoutChangingSelection() {
        let store = BrowserStore()
        let first = store.addTab(select: true)
        let second = store.addTab(select: false)
        let third = store.addTab(select: false)

        store.moveTabs(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(store.tabs.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(store.selectedTabID, first.id)
    }

    func testAppVersionIs024() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.2.4")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "6")
    }
}
