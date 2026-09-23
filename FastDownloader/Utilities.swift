import Foundation
import CryptoKit

enum FilenameResolver {
    static func filename(for response: URLResponse?, fallbackURL: URL) -> String {
        if let suggested = response?.suggestedFilename, !suggested.isEmpty {
            return sanitize(suggested)
        }

        let component = fallbackURL.lastPathComponent
        if !component.isEmpty && component != "/" {
            return sanitize(component.removingPercentEncoding ?? component)
        }

        return "download-" + UUID().uuidString
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download-" + UUID().uuidString : cleaned
    }
}

enum FileHasher {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ByteFormatter {
    static let shared: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static func string(_ value: Int64) -> String {
        shared.string(fromByteCount: value)
    }
}


enum SpeedFormatter {
    static func string(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return ByteFormatter.string(Int64(bytesPerSecond)) + "/s"
    }
}

enum DurationFormatter {
    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }

        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(max(1, total))s left"
        }

        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m left" : "\(minutes)m \(remainder)s left"
        }

        let hours = minutes / 60
        let minuteRemainder = minutes % 60
        return minuteRemainder == 0 ? "\(hours)h left" : "\(hours)h \(minuteRemainder)m left"
    }
}
