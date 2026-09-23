import Foundation
import Combine

enum DownloadIntegrityStatus: String, Codable {
    case localSHA256
    case sizeVerified
    case serverSHA256Verified

    var title: String {
        switch self {
        case .localSHA256: return "Local SHA-256 calculated"
        case .sizeVerified: return "File size verified"
        case .serverSHA256Verified: return "SHA-256 verified against server"
        }
    }
}

enum DownloadTransferMode: String, Codable {
    case single
    case turbo

    var title: String {
        switch self {
        case .single: return "Single"
        case .turbo: return "Turbo"
        }
    }
}

struct DownloadSegment: Identifiable, Codable, Equatable {
    var id: Int { index }

    let index: Int
    let startByte: Int64
    let endByte: Int64
    var receivedBytes: Int64 = 0
    var completed: Bool = false
    var partFile: String?
    var resumeDataFile: String?
    var taskIdentifier: Int?

    var length: Int64 {
        endByte - startByte + 1
    }
}

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
    var responseETag: String?
    var responseLastModified: String?
    var responseContentEncoding: String?
    var serverAcceptsRanges: Bool?
    var expectedSHA256Base64: String?
    var integrityStatus: DownloadIntegrityStatus?
    var transferMode: DownloadTransferMode?
    var segments: [DownloadSegment]?
    var turboFallbackReason: String?

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
        etaSeconds: Double? = nil,
        responseETag: String? = nil,
        responseLastModified: String? = nil,
        responseContentEncoding: String? = nil,
        serverAcceptsRanges: Bool? = nil,
        expectedSHA256Base64: String? = nil,
        integrityStatus: DownloadIntegrityStatus? = nil,
        transferMode: DownloadTransferMode? = nil,
        segments: [DownloadSegment]? = nil,
        turboFallbackReason: String? = nil
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
        self.responseETag = responseETag
        self.responseLastModified = responseLastModified
        self.responseContentEncoding = responseContentEncoding
        self.serverAcceptsRanges = serverAcceptsRanges
        self.expectedSHA256Base64 = expectedSHA256Base64
        self.integrityStatus = integrityStatus
        self.transferMode = transferMode
        self.segments = segments
        self.turboFallbackReason = turboFallbackReason
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
        static let downloadNotifications = "settings.downloadNotifications"
        static let turboEnabled = "settings.turboEnabled"
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

    @Published var downloadNotifications: Bool {
        didSet { UserDefaults.standard.set(downloadNotifications, forKey: Key.downloadNotifications) }
    }

    @Published var turboEnabled: Bool {
        didSet { UserDefaults.standard.set(turboEnabled, forKey: Key.turboEnabled) }
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
        if defaults.object(forKey: Key.downloadNotifications) == nil {
            defaults.set(true, forKey: Key.downloadNotifications)
        }
        if defaults.object(forKey: Key.turboEnabled) == nil {
            defaults.set(true, forKey: Key.turboEnabled)
        }

        allowCellular = defaults.bool(forKey: Key.allowCellular)
        allowConstrained = defaults.bool(forKey: Key.allowConstrained)
        verifyDownloads = defaults.bool(forKey: Key.verifyDownloads)
        openPopupsInTabs = defaults.bool(forKey: Key.openPopupsInTabs)
        downloadNotifications = defaults.bool(forKey: Key.downloadNotifications)
        turboEnabled = defaults.bool(forKey: Key.turboEnabled)
    }
}
