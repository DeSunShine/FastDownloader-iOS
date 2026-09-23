import Foundation

struct ContentRangeInfo: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64
}

enum ContentRangeParser {
    static func parse(_ value: String?) -> ContentRangeInfo? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }

        let payload = trimmed.dropFirst(6)
        let pieces = payload.split(separator: "/", maxSplits: 1)
        guard pieces.count == 2,
              let total = Int64(pieces[1]),
              total > 0
        else { return nil }

        let rangeParts = pieces[0].split(separator: "-", maxSplits: 1)
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]),
              start >= 0,
              end >= start,
              end < total
        else { return nil }

        return ContentRangeInfo(start: start, end: end, total: total)
    }
}

enum RetryAfterParser {
    static func delay(from value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

enum TurboPolicy {
    static let minimumTurboSize: Int64 = 20 * 1024 * 1024
    static let initialConcurrency = 2
    static let maximumAutomaticRetries = 6

    static func rateLimitDelay(retryAfter: String?, strike: Int, now: Date = Date()) -> TimeInterval {
        if let serverDelay = RetryAfterParser.delay(from: retryAfter, now: now) {
            return min(max(serverDelay, 1), 120)
        }

        let exponent = max(0, min(strike - 1, 5))
        return min(5 * pow(2, Double(exponent)), 120)
    }

    static func networkRetryDelay(attempt: Int) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 5))
        return min(pow(2, Double(exponent)), 30)
    }

    static func reducedConcurrency(current: Int) -> Int {
        max(1, current / 2)
    }

    static func segmentCount(for totalBytes: Int64) -> Int {
        switch totalBytes {
        case ..<minimumTurboSize:
            return 1
        case ..<(64 * 1024 * 1024):
            return 2
        case ..<(512 * 1024 * 1024):
            return 4
        default:
            return 8
        }
    }

    static func makeSegments(totalBytes: Int64, count requestedCount: Int) -> [DownloadSegment] {
        guard totalBytes > 0 else { return [] }

        let count = max(1, min(requestedCount, Int(totalBytes)))
        let base = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)

        var result: [DownloadSegment] = []
        var cursor: Int64 = 0

        for index in 0..<count {
            let extra: Int64 = Int64(index) < remainder ? 1 : 0
            let length = base + extra
            let end = cursor + length - 1
            result.append(
                DownloadSegment(
                    index: index,
                    startByte: cursor,
                    endByte: end
                )
            )
            cursor = end + 1
        }

        return result
    }

    static func strongValidator(etag: String?, lastModified: String?) -> String? {
        if let etag {
            let trimmed = etag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.lowercased().hasPrefix("w/") {
                return trimmed
            }
        }

        if let lastModified {
            let trimmed = lastModified.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }
}

enum TurboTaskDescription {
    static func single(itemID: UUID) -> String {
        "single|\(itemID.uuidString)"
    }

    static func segment(itemID: UUID, index: Int) -> String {
        "segment|\(itemID.uuidString)|\(index)"
    }

    static func parse(_ value: String?) -> (itemID: UUID, segmentIndex: Int?)? {
        guard let value else { return nil }

        let parts = value.split(separator: "|")
        if parts.count == 2,
           parts[0] == "single",
           let id = UUID(uuidString: String(parts[1])) {
            return (id, nil)
        }

        if parts.count == 3,
           parts[0] == "segment",
           let id = UUID(uuidString: String(parts[1])),
           let index = Int(parts[2]) {
            return (id, index)
        }

        if let id = UUID(uuidString: value) {
            return (id, nil)
        }

        return nil
    }
}


final class TurboRangeProbe: NSObject, URLSessionDataDelegate {
    typealias Completion = (Result<HTTPURLResponse, Error>) -> Void

    private var session: URLSession?
    private var completion: Completion?
    private var finished = false

    static func start(request: URLRequest, completion: @escaping Completion) {
        let probe = TurboRangeProbe()
        probe.run(request: request, completion: completion)
    }

    private func run(request: URLRequest, completion: @escaping Completion) {
        self.completion = completion

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        let task = session.dataTask(with: request)
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.cancel)

        guard let http = response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }

        finish(.success(http))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished, let error else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        guard !finished else { return }
        finished = true
        let completion = self.completion
        self.completion = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion?(result)
    }
}
