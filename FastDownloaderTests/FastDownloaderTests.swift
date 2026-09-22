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
}
