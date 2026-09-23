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
            requestHeaders: ["Referer": "https://example.com"],
            bytesPerSecond: 2_048,
            etaSeconds: 12.5
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

    func testHTTPContentDigestParsing() {
        XCTAssertEqual(
            HTTPDigestParser.sha256Base64(
                contentDigest: "sha-256=:dW5nd3Y0OEJ6K3BCUVVEZVhhNGlJN0FEWWFPV0YzcWN0QkQvWWZJQUZhMD0=:",
                legacyDigest: nil
            ),
            "dW5nd3Y0OEJ6K3BCUVVEZVhhNGlJN0FEWWFPV0YzcWN0QkQvWWZJQUZhMD0="
        )

        XCTAssertEqual(
            HTTPDigestParser.sha256Base64(
                contentDigest: nil,
                legacyDigest: "sha-256=YWJjZA=="
            ),
            "YWJjZA=="
        )
    }

    func testSHA256DigestProducesHexAndBase64() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try FileHasher.sha256Digest(of: url)
        XCTAssertEqual(
            digest.hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            digest.base64,
            "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
        )
    }

    func testDownloadNotificationText() {
        let completed = DownloadItem(
            sourceURL: "https://example.com/file.bin",
            filename: "file.bin",
            state: .completed,
            receivedBytes: 100_000_000,
            expectedBytes: 100_000_000,
            integrityStatus: .sizeVerified
        )
        let completedBody = DownloadNotificationManager.completionBody(for: completed)
        XCTAssertTrue(completedBody.contains("file.bin"))
        XCTAssertTrue(completedBody.contains("File size verified"))

        var failed = completed
        failed.state = .failed
        failed.errorMessage = "Connection lost"
        XCTAssertEqual(
            DownloadNotificationManager.failureBody(for: failed),
            "file.bin • Connection lost"
        )
    }

    func testContentRangeParsing() {
        XCTAssertEqual(
            ContentRangeParser.parse("bytes 0-0/100000000"),
            ContentRangeInfo(start: 0, end: 0, total: 100_000_000)
        )
        XCTAssertNil(ContentRangeParser.parse("bytes 0-99/*"))
        XCTAssertNil(ContentRangeParser.parse("bytes 100-99/1000"))
    }

    func testAdaptiveTurboPolicy() {
        XCTAssertEqual(TurboPolicy.segmentCount(for: 10 * 1024 * 1024), 1)
        XCTAssertEqual(TurboPolicy.segmentCount(for: 30 * 1024 * 1024), 2)
        XCTAssertEqual(TurboPolicy.segmentCount(for: 100 * 1024 * 1024), 4)
        XCTAssertEqual(TurboPolicy.segmentCount(for: 700 * 1024 * 1024), 8)
    }

    func testTurboSegmentsCoverFileExactlyOnce() {
        let total: Int64 = 100_000_003
        let segments = TurboPolicy.makeSegments(totalBytes: total, count: 4)

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments.first?.startByte, 0)
        XCTAssertEqual(segments.last?.endByte, total - 1)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.length }, total)

        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(pair.0.endByte + 1, pair.1.startByte)
        }
    }

    func testTurboTaskDescriptionRoundTrip() {
        let id = UUID()
        let segment = TurboTaskDescription.segment(itemID: id, index: 3)
        let parsed = TurboTaskDescription.parse(segment)
        XCTAssertEqual(parsed?.itemID, id)
        XCTAssertEqual(parsed?.segmentIndex, 3)

        let single = TurboTaskDescription.single(itemID: id)
        XCTAssertEqual(TurboTaskDescription.parse(single)?.itemID, id)
        XCTAssertNil(TurboTaskDescription.parse(single)?.segmentIndex)
    }

    func testTurboValidatorRejectsWeakETag() {
        XCTAssertEqual(
            TurboPolicy.strongValidator(etag: "\"strong-tag\"", lastModified: nil),
            "\"strong-tag\""
        )
        XCTAssertEqual(
            TurboPolicy.strongValidator(etag: "W/\"weak-tag\"", lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"),
            "Wed, 21 Oct 2015 07:28:00 GMT"
        )
    }

    func testRetryAfterParserSeconds() {
        XCTAssertEqual(RetryAfterParser.delay(from: "30"), 30)
        XCTAssertNil(RetryAfterParser.delay(from: "nonsense"))
    }

    func testTurboBackoffPolicy() {
        XCTAssertEqual(TurboPolicy.reducedConcurrency(current: 4), 2)
        XCTAssertEqual(TurboPolicy.reducedConcurrency(current: 3), 1)
        XCTAssertEqual(TurboPolicy.reducedConcurrency(current: 1), 1)

        XCTAssertEqual(
            TurboPolicy.rateLimitDelay(retryAfter: nil, strike: 1),
            5
        )
        XCTAssertEqual(
            TurboPolicy.rateLimitDelay(retryAfter: nil, strike: 3),
            20
        )
        XCTAssertEqual(TurboPolicy.networkRetryDelay(attempt: 1), 1)
        XCTAssertEqual(TurboPolicy.networkRetryDelay(attempt: 5), 16)
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

    func testDirectNavigationEntersLoadingStateImmediately() {
        let store = BrowserStore()
        let tab = store.addTab(select: true)

        _ = store.navigate("https://example.invalid", in: tab)

        XCTAssertTrue(tab.isLoading)
        XCTAssertEqual(tab.urlString, "https://example.invalid")
        XCTAssertNil(tab.navigationError)
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

    func testDurationFormatting() {
        XCTAssertEqual(DurationFormatter.remaining(45), "45s left")
        XCTAssertEqual(DurationFormatter.remaining(65), "1m 5s left")
        XCTAssertEqual(DurationFormatter.remaining(3_660), "1h 1m left")
    }

    func testAppVersionIs041() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.4.1")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "12")
    }
}
