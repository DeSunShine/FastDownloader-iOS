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

enum TurboPolicy {
    static let minimumTurboSize: Int64 = 20 * 1024 * 1024

    static func segmentCount(for totalBytes: Int64) -> Int {
        switch totalBytes {
        case ..<minimumTurboSize:
            return 1
        case ..<(100 * 1024 * 1024):
            return 2
        case ..<(500 * 1024 * 1024):
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
