import Foundation
import Combine

enum DownloadState: String, Codable, CaseIterable {
    case queued
    case downloading
    case paused
    case verifying
    case completed
    case failed

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .verifying: return "Verifying"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

struct DownloadItem: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceURL: String
    var sourcePage: String?
    var filename: String
    var createdAt: Date
    var state: DownloadState
    var receivedBytes: Int64
    var expectedBytes: Int64
    var localRelativePath: String?
    var errorMessage: String?
    var sha256: String?
    var taskIdentifier: Int?
    var requestHeaders: [String: String]
    var requestHTTPMethod: String
    var requestBodyBase64: String?
    var resumeDataFile: String?
    var bytesPerSecond: Double?
    var etaSeconds: Double?

    init(
        id: UUID = UUID(),
        sourceURL: String,
        sourcePage: String? = nil,
        filename: String,
        createdAt: Date = Date(),
        state: DownloadState = .queued,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64 = 0,
        localRelativePath: String? = nil,
        errorMessage: String? = nil,
        sha256: String? = nil,
        taskIdentifier: Int? = nil,
        requestHeaders: [String: String] = [:],
        requestHTTPMethod: String = "GET",
        requestBodyBase64: String? = nil,
        resumeDataFile: String? = nil,
        bytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourcePage = sourcePage
        self.filename = filename
        self.createdAt = createdAt
        self.state = state
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.localRelativePath = localRelativePath
        self.errorMessage = errorMessage
        self.sha256 = sha256
        self.taskIdentifier = taskIdentifier
        self.requestHeaders = requestHeaders
        self.requestHTTPMethod = requestHTTPMethod
        self.requestBodyBase64 = requestBodyBase64
        self.resumeDataFile = resumeDataFile
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
    }

    var progress: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let allowCellular = "settings.allowCellular"
        static let allowConstrained = "settings.allowConstrained"
        static let verifyDownloads = "settings.verifyDownloads"
        static let openPopupsInTabs = "settings.openPopupsInTabs"
    }

    @Published var allowCellular: Bool {
        didSet { UserDefaults.standard.set(allowCellular, forKey: Key.allowCellular) }
    }

    @Published var allowConstrained: Bool {
        didSet { UserDefaults.standard.set(allowConstrained, forKey: Key.allowConstrained) }
    }

    @Published var verifyDownloads: Bool {
        didSet { UserDefaults.standard.set(verifyDownloads, forKey: Key.verifyDownloads) }
    }

    @Published var openPopupsInTabs: Bool {
        didSet { UserDefaults.standard.set(openPopupsInTabs, forKey: Key.openPopupsInTabs) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.allowCellular) == nil {
            defaults.set(true, forKey: Key.allowCellular)
        }
        if defaults.object(forKey: Key.allowConstrained) == nil {
            defaults.set(true, forKey: Key.allowConstrained)
        }
        if defaults.object(forKey: Key.verifyDownloads) == nil {
            defaults.set(true, forKey: Key.verifyDownloads)
        }
        if defaults.object(forKey: Key.openPopupsInTabs) == nil {
            defaults.set(true, forKey: Key.openPopupsInTabs)
        }

        allowCellular = defaults.bool(forKey: Key.allowCellular)
        allowConstrained = defaults.bool(forKey: Key.allowConstrained)
        verifyDownloads = defaults.bool(forKey: Key.verifyDownloads)
        openPopupsInTabs = defaults.bool(forKey: Key.openPopupsInTabs)
    }
}
