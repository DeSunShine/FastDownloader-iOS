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
