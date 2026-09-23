import Foundation
import Combine

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    var backgroundCompletionHandler: (() -> Void)?

    private let sessionIdentifier = "com.desunshine.fastdownloader.background"
    private let fileManager = FileManager.default
    private var taskToItem: [Int: UUID] = [:]
    private var progressSamples: [UUID: (date: Date, bytes: Int64, speed: Double)] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        createDirectoriesIfNeeded()
        loadItems()
        reconnectBackgroundTasks()
    }

    private var applicationSupportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FastDownloader", isDirectory: true)
    }

    private var metadataURL: URL {
        applicationSupportDirectory.appendingPathComponent("downloads.json")
    }

    private var resumeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Resume", isDirectory: true)
    }

    private var partsRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Parts", isDirectory: true)
    }

    private var downloadDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func partsDirectory(for id: UUID) -> URL {
        partsRootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func createDirectoriesIfNeeded() {
        try? fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: partsRootDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
    }

    func start(
        request originalRequest: URLRequest,
        sourcePage: String?,
        cookies: [HTTPCookie],
        userAgent: String?,
        preferredFilename: String? = nil
    ) {
        guard let url = originalRequest.url else { return }

        DownloadNotificationManager.shared.requestAuthorizationIfNeeded()

        var request = originalRequest
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = AppSettings.shared.allowCellular
        request.allowsConstrainedNetworkAccess = AppSettings.shared.allowConstrained
        request.allowsExpensiveNetworkAccess = true

        if let sourcePage, request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(sourcePage, forHTTPHeaderField: "Referer")
        }

        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        if !cookies.isEmpty {
            let fields = HTTPCookie.requestHeaderFields(with: cookies)
            if let cookieHeader = fields["Cookie"] {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        let filename = FilenameResolver.sanitize(
            preferredFilename ?? FilenameResolver.filename(for: nil, fallbackURL: url)
        )

        let item = DownloadItem(
            sourceURL: url.absoluteString,
            sourcePage: sourcePage,
            filename: filename,
            state: .queued,
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestHTTPMethod: request.httpMethod ?? "GET",
            requestBodyBase64: request.httpBody?.base64EncodedString()
        )

        items.insert(item, at: 0)
        saveItems()

        let method = (request.httpMethod ?? "GET").uppercased()
        let canProbeTurbo =
            AppSettings.shared.turboEnabled &&
            method == "GET" &&
            request.httpBody == nil &&
            request.httpBodyStream == nil &&
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")

        if canProbeTurbo {
            probeAndStartTurbo(itemID: item.id, request: request)
        } else {
            startSingleDownload(itemID: item.id, request: request, fallbackReason: nil)
        }
    }

    func pause(id: UUID) {
        guard let itemIndex = index(of: id), items[itemIndex].state == .downloading else { return }

        update(id) {
            $0.state = .paused
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
        }
        progressSamples[id] = nil
        saveItems()

        if items[itemIndex].transferMode == .turbo {
            pauseTurbo(id: id)
        } else {
            pauseSingle(id: id)
        }
    }

    func resume(id: UUID) {
        guard let itemIndex = index(of: id) else { return }
        let item = items[itemIndex]
        guard item.state == .paused || item.state == .failed else { return }

        if item.transferMode == .turbo, let segments = item.segments, !segments.isEmpty {
            if segments.allSatisfy(\.completed) {
                mergeTurboDownload(id: id)
            } else {
                resumeTurbo(id: id)
            }
            return
        }

        resumeSingle(id: id)
    }

    func retry(id: UUID) {
        guard let itemIndex = index(of: id) else { return }
        let item = items[itemIndex]

        if item.transferMode == .turbo, let segments = item.segments, !segments.isEmpty {
            update(id) {
                $0.errorMessage = nil
                $0.bytesPerSecond = nil
                $0.etaSeconds = nil
            }

            if segments.allSatisfy(\.completed) {
                mergeTurboDownload(id: id)
            } else {
                resumeTurbo(id: id)
            }
            return
        }

        if let resume = item.resumeDataFile {
            try? fileManager.removeItem(at: resumeDirectory.appendingPathComponent(resume))
        }

        update(id) {
            $0.receivedBytes = 0
            $0.expectedBytes = 0
            $0.resumeDataFile = nil
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            $0.state = .paused
        }
        progressSamples[id] = nil
        resumeSingle(id: id)
    }

    func delete(id: UUID) {
        cancelTasks(for: id)

        if let item = items.first(where: { $0.id == id }) {
            if let relative = item.localRelativePath {
                try? fileManager.removeItem(at: downloadDirectory.appendingPathComponent(relative))
            }
            if let resume = item.resumeDataFile {
                try? fileManager.removeItem(at: resumeDirectory.appendingPathComponent(resume))
            }
            for segment in item.segments ?? [] {
                if let resume = segment.resumeDataFile {
                    try? fileManager.removeItem(at: resumeDirectory.appendingPathComponent(resume))
                }
            }
        }

        try? fileManager.removeItem(at: partsDirectory(for: id))
        items.removeAll { $0.id == id }
        progressSamples[id] = nil
        saveItems()
    }

    func localURL(for item: DownloadItem) -> URL? {
        guard let relative = item.localRelativePath else { return nil }
        let url = downloadDirectory.appendingPathComponent(relative)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func probeAndStartTurbo(itemID: UUID, request: URLRequest) {
        var probe = request
        probe.httpMethod = "GET"
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        TurboRangeProbe.start(request: probe) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.index(of: itemID) != nil else { return }

                switch result {
                case .failure:
                    self.startSingleDownload(
                        itemID: itemID,
                        request: request,
                        fallbackReason: "Turbo probe unavailable"
                    )

                case .success(let response):
                    if response.statusCode == 429 || response.statusCode == 503 {
                        self.scheduleProbeRetry(
                            itemID: itemID,
                            request: request,
                            response: response
                        )
                        return
                    }

                    guard response.statusCode == 206,
                          let range = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range")),
                          range.start == 0,
                          range.end == 0,
                          range.total > 0
                    else {
                        self.startSingleDownload(
                            itemID: itemID,
                            request: request,
                            fallbackReason: "Server does not support byte ranges"
                        )
                        return
                    }

                    let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()

                    guard encoding == nil || encoding == "" || encoding == "identity" else {
                        self.startSingleDownload(
                            itemID: itemID,
                            request: request,
                            fallbackReason: "Compressed range response"
                        )
                        return
                    }

                    let etag = response.value(forHTTPHeaderField: "ETag")
                    let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
                    guard let validator = TurboPolicy.strongValidator(
                        etag: etag,
                        lastModified: lastModified
                    ) else {
                        self.startSingleDownload(
                            itemID: itemID,
                            request: request,
                            fallbackReason: "Server did not provide a safe resume validator"
                        )
                        return
                    }

                    let count = TurboPolicy.segmentCount(for: range.total)
                    guard count > 1 else {
                        self.update(itemID) {
                            $0.expectedBytes = range.total
                            $0.responseETag = etag
                            $0.responseLastModified = lastModified
                            $0.serverAcceptsRanges = true
                        }
                        self.startSingleDownload(itemID: itemID, request: request, fallbackReason: nil)
                        return
                    }

                    self.startTurboDownload(
                        itemID: itemID,
                        request: request,
                        totalBytes: range.total,
                        segmentCount: count,
                        validator: validator,
                        etag: etag,
                        lastModified: lastModified,
                        suggestedFilename: response.suggestedFilename
                    )
                }
            }
        }
    }

    private func startTurboDownload(
        itemID: UUID,
        request: URLRequest,
        totalBytes: Int64,
        segmentCount: Int,
        validator: String,
        etag: String?,
        lastModified: String?,
        suggestedFilename: String?
    ) {
        let segments = TurboPolicy.makeSegments(totalBytes: totalBytes, count: segmentCount)
        guard segments.count > 1 else {
            startSingleDownload(itemID: itemID, request: request, fallbackReason: nil)
            return
        }

        let directory = partsDirectory(for: itemID)
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        update(itemID) {
            $0.transferMode = .turbo
            $0.segments = segments
            $0.turboFallbackReason = nil
            $0.expectedBytes = totalBytes
            $0.receivedBytes = 0
            $0.responseETag = etag
            $0.responseLastModified = lastModified
            $0.responseContentEncoding = "identity"
            $0.serverAcceptsRanges = true
            $0.turboConcurrencyLimit = min(TurboPolicy.initialConcurrency, segments.count)
            $0.turboRateLimitCount = 0
            $0.rateLimitedUntil = nil
            $0.errorMessage = nil
            $0.state = .downloading
            if let suggestedFilename, !suggestedFilename.isEmpty {
                $0.filename = FilenameResolver.sanitize(suggestedFilename)
            }
        }

        saveItems()
        launchTurboTasksIfNeeded(id: itemID)
    }

    private func startSegmentTask(
        itemID: UUID,
        segmentIndex: Int,
        baseRequest: URLRequest,
        validator: String,
        resumeData: Data?
    ) {
        guard let itemIndex = index(of: itemID),
              var segments = items[itemIndex].segments,
              let segmentPosition = segments.firstIndex(where: { $0.index == segmentIndex })
        else { return }

        let segment = segments[segmentPosition]
        let task: URLSessionDownloadTask

        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = baseRequest
            request.httpMethod = "GET"
            request.setValue(
                "bytes=\(segment.startByte)-\(segment.endByte)",
                forHTTPHeaderField: "Range"
            )
            request.setValue(validator, forHTTPHeaderField: "If-Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            task = session.downloadTask(with: request)
        }

        task.taskDescription = TurboTaskDescription.segment(
            itemID: itemID,
            index: segmentIndex
        )
        taskToItem[task.taskIdentifier] = itemID

        segments[segmentPosition].taskIdentifier = task.taskIdentifier
        segments[segmentPosition].nextRetryAt = nil
        update(itemID) {
            $0.segments = segments
            $0.state = .downloading
        }

        task.resume()
    }

    private func scheduleProbeRetry(
        itemID: UUID,
        request: URLRequest,
        response: HTTPURLResponse
    ) {
        guard let itemIndex = index(of: itemID) else { return }

        let strike = (items[itemIndex].turboRateLimitCount ?? 0) + 1
        guard strike <= TurboPolicy.maximumAutomaticRetries else {
            fail(
                id: itemID,
                message: "The server is rate-limiting requests (HTTP \(response.statusCode)). Try again later.",
                notify: true
            )
            return
        }

        let delay = TurboPolicy.rateLimitDelay(
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            strike: strike
        )
        let retryAt = Date().addingTimeInterval(delay)

        update(itemID) {
            $0.turboRateLimitCount = strike
            $0.rateLimitedUntil = retryAt
            $0.state = .queued
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
        }
        saveItems()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let currentIndex = self.index(of: itemID),
                  self.items[currentIndex].state == .queued
            else { return }

            self.update(itemID) { $0.rateLimitedUntil = nil }
            self.probeAndStartTurbo(itemID: itemID, request: request)
        }
    }

    private func launchTurboTasksIfNeeded(id: UUID) {
        guard let itemIndex = index(of: id),
              items[itemIndex].transferMode == .turbo,
              items[itemIndex].state == .downloading,
              let segmentsSnapshot = items[itemIndex].segments,
              let baseRequest = reconstructedRequest(from: items[itemIndex]),
              let validator = TurboPolicy.strongValidator(
                etag: items[itemIndex].responseETag,
                lastModified: items[itemIndex].responseLastModified
              )
        else { return }

        let now = Date()

        if let limitedUntil = items[itemIndex].rateLimitedUntil, limitedUntil > now {
            scheduleTurboLaunch(id: id, after: limitedUntil.timeIntervalSince(now))
            return
        }

        let limit = max(
            1,
            min(
                items[itemIndex].turboConcurrencyLimit ?? TurboPolicy.initialConcurrency,
                segmentsSnapshot.count
            )
        )
        let active = segmentsSnapshot.filter {
            !$0.completed && $0.taskIdentifier != nil
        }.count
        var slots = max(0, limit - active)

        guard slots > 0 else { return }

        let candidates = segmentsSnapshot
            .filter {
                !$0.completed &&
                $0.taskIdentifier == nil &&
                ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
            }
            .sorted { $0.index < $1.index }

        for segment in candidates {
            guard slots > 0 else { break }

            var resumeData: Data?

            if let resumeName = segment.resumeDataFile {
                let resumeURL = resumeDirectory.appendingPathComponent(resumeName)
                resumeData = try? Data(contentsOf: resumeURL)
                try? fileManager.removeItem(at: resumeURL)

                update(id) { item in
                    guard var segments = item.segments,
                          let position = segments.firstIndex(where: { $0.index == segment.index })
                    else { return }
                    segments[position].resumeDataFile = nil
                    item.segments = segments
                }
            }

            if resumeData == nil, segment.receivedBytes > 0 {
                update(id) { item in
                    guard var segments = item.segments,
                          let position = segments.firstIndex(where: { $0.index == segment.index })
                    else { return }

                    segments[position].receivedBytes = 0
                    item.segments = segments
                    item.receivedBytes = segments.reduce(0) {
                        $0 + ($1.completed ? $1.length : $1.receivedBytes)
                    }
                }
            }

            startSegmentTask(
                itemID: id,
                segmentIndex: segment.index,
                baseRequest: baseRequest,
                validator: validator,
                resumeData: resumeData
            )
            slots -= 1
        }

        if slots > 0 {
            let futureDates = segmentsSnapshot.compactMap { segment -> Date? in
                guard !segment.completed,
                      segment.taskIdentifier == nil,
                      let retryAt = segment.nextRetryAt,
                      retryAt > now
                else { return nil }
                return retryAt
            }

            if let earliest = futureDates.min() {
                scheduleTurboLaunch(id: id, after: earliest.timeIntervalSince(now))
            }
        }

        saveItems()
    }

    private func scheduleTurboLaunch(id: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.25, delay)) { [weak self] in
            guard let self,
                  let itemIndex = self.index(of: id),
                  self.items[itemIndex].state == .downloading,
                  self.items[itemIndex].transferMode == .turbo
            else { return }

            if let until = self.items[itemIndex].rateLimitedUntil, until <= Date() {
                self.update(id) { $0.rateLimitedUntil = nil }
            }

            self.launchTurboTasksIfNeeded(id: id)
        }
    }

    private func handleTurboRateLimit(
        id: UUID,
        segmentIndex: Int,
        response: HTTPURLResponse
    ) {
        guard let itemIndex = index(of: id),
              items[itemIndex].transferMode == .turbo,
              let segments = items[itemIndex].segments,
              let position = segments.firstIndex(where: { $0.index == segmentIndex })
        else { return }

        let strike = (items[itemIndex].turboRateLimitCount ?? 0) + 1
        guard strike <= TurboPolicy.maximumAutomaticRetries else {
            fail(
                id: id,
                message: "The server keeps rate-limiting Turbo requests (HTTP \(response.statusCode)). Retry later.",
                notify: true
            )
            return
        }

        let currentLimit = items[itemIndex].turboConcurrencyLimit ?? TurboPolicy.initialConcurrency
        let newLimit = TurboPolicy.reducedConcurrency(current: currentLimit)
        let delay = TurboPolicy.rateLimitDelay(
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            strike: strike
        )
        let retryAt = Date().addingTimeInterval(delay)

        if let resumeName = segments[position].resumeDataFile {
            try? fileManager.removeItem(at: resumeDirectory.appendingPathComponent(resumeName))
        }

        update(id) { item in
            guard var currentSegments = item.segments,
                  let currentPosition = currentSegments.firstIndex(where: { $0.index == segmentIndex })
            else { return }

            currentSegments[currentPosition].taskIdentifier = nil
            currentSegments[currentPosition].resumeDataFile = nil
            currentSegments[currentPosition].receivedBytes = 0
            currentSegments[currentPosition].nextRetryAt = retryAt
            currentSegments[currentPosition].retryCount =
                (currentSegments[currentPosition].retryCount ?? 0) + 1

            item.segments = currentSegments
            item.receivedBytes = currentSegments.reduce(0) {
                $0 + ($1.completed ? $1.length : $1.receivedBytes)
            }
            item.turboConcurrencyLimit = newLimit
            item.turboRateLimitCount = strike
            item.rateLimitedUntil = retryAt
            item.errorMessage = nil
            item.bytesPerSecond = nil
            item.etaSeconds = nil
            item.state = .downloading
        }

        progressSamples[id] = nil
        saveItems()
        suspendTurboTasksForBackoff(id: id)
        scheduleTurboLaunch(id: id, after: delay)
    }

    private func suspendTurboTasksForBackoff(id: UUID) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            for task in tasks {
                guard let downloadTask = task as? URLSessionDownloadTask,
                      let identity = TurboTaskDescription.parse(task.taskDescription),
                      identity.itemID == id,
                      let segmentIndex = identity.segmentIndex
                else { continue }

                downloadTask.cancel(byProducingResumeData: { data in
                    DispatchQueue.main.async {
                        guard let itemIndex = self.index(of: id),
                              var segments = self.items[itemIndex].segments,
                              let position = segments.firstIndex(where: { $0.index == segmentIndex }),
                              !segments[position].completed
                        else { return }

                        segments[position].taskIdentifier = nil

                        if let data {
                            let fileName = id.uuidString + "-segment-\(segmentIndex).resume"
                            let url = self.resumeDirectory.appendingPathComponent(fileName)
                            if (try? data.write(to: url, options: .atomic)) != nil {
                                segments[position].resumeDataFile = fileName
                            }
                        }

                        self.update(id) { $0.segments = segments }
                        self.saveItems()
                    }
                })
            }
        }
    }

    private func startSingleDownload(
        itemID: UUID,
        request originalRequest: URLRequest,
        fallbackReason: String?
    ) {
        guard index(of: itemID) != nil else { return }

        var request = originalRequest
        request.setValue(nil, forHTTPHeaderField: "Range")
        request.setValue(nil, forHTTPHeaderField: "If-Range")

        let task = session.downloadTask(with: request)
        task.taskDescription = TurboTaskDescription.single(itemID: itemID)
        taskToItem[task.taskIdentifier] = itemID

        update(itemID) {
            $0.transferMode = .single
            $0.segments = nil
            $0.turboFallbackReason = fallbackReason
            $0.taskIdentifier = task.taskIdentifier
            $0.resumeDataFile = nil
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            $0.state = .downloading
        }

        progressSamples[itemID] = nil
        saveItems()
        task.resume()
    }

    private func pauseSingle(id: UUID) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            guard let task = tasks.first(where: {
                guard let identity = TurboTaskDescription.parse($0.taskDescription) else { return false }
                return identity.itemID == id && identity.segmentIndex == nil
            }) as? URLSessionDownloadTask else {
                return
            }

            task.cancel(byProducingResumeData: { data in
                DispatchQueue.main.async {
                    self.update(id) {
                        $0.taskIdentifier = nil
                        $0.resumeDataFile = nil
                    }

                    guard let data else {
                        self.saveItems()
                        return
                    }

                    let fileName = id.uuidString + ".resume"
                    let url = self.resumeDirectory.appendingPathComponent(fileName)
                    do {
                        try data.write(to: url, options: .atomic)
                        self.update(id) { $0.resumeDataFile = fileName }
                    } catch {
                        self.update(id) {
                            $0.errorMessage = "Could not save resume data: " + error.localizedDescription
                        }
                    }
                    self.saveItems()
                }
            })
        }
    }

    private func pauseTurbo(id: UUID) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            let segmentTasks = tasks.compactMap { task -> (URLSessionDownloadTask, Int)? in
                guard let downloadTask = task as? URLSessionDownloadTask,
                      let identity = TurboTaskDescription.parse(task.taskDescription),
                      identity.itemID == id,
                      let segmentIndex = identity.segmentIndex
                else { return nil }
                return (downloadTask, segmentIndex)
            }

            for (task, segmentIndex) in segmentTasks {
                task.cancel(byProducingResumeData: { data in
                    DispatchQueue.main.async {
                        guard let itemIndex = self.index(of: id),
                              var segments = self.items[itemIndex].segments,
                              let position = segments.firstIndex(where: { $0.index == segmentIndex })
                        else { return }

                        segments[position].taskIdentifier = nil
                        segments[position].resumeDataFile = nil

                        if let data {
                            let fileName = id.uuidString + "-segment-\(segmentIndex).resume"
                            let url = self.resumeDirectory.appendingPathComponent(fileName)
                            if (try? data.write(to: url, options: .atomic)) != nil {
                                segments[position].resumeDataFile = fileName
                            }
                        }

                        self.update(id) { $0.segments = segments }
                        self.saveItems()
                    }
                })
            }
        }
    }

    private func resumeSingle(id: UUID) {
        guard let itemIndex = index(of: id) else { return }
        let item = items[itemIndex]

        var task: URLSessionDownloadTask?
        var resumedFromPartialData = false

        if let resumeDataFile = item.resumeDataFile {
            let resumeURL = resumeDirectory.appendingPathComponent(resumeDataFile)
            if let data = try? Data(contentsOf: resumeURL) {
                task = session.downloadTask(withResumeData: data)
                resumedFromPartialData = true
                try? fileManager.removeItem(at: resumeURL)
            }
        }

        if task == nil, let request = reconstructedRequest(from: item) {
            task = session.downloadTask(with: request)
        }

        guard let task else {
            fail(id: id, message: "The original request can no longer be reconstructed.", notify: true)
            return
        }

        task.taskDescription = TurboTaskDescription.single(itemID: id)
        taskToItem[task.taskIdentifier] = id

        update(id) {
            $0.transferMode = .single
            $0.state = .downloading
            $0.errorMessage = nil
            $0.resumeDataFile = nil
            $0.taskIdentifier = task.taskIdentifier
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            if !resumedFromPartialData {
                $0.receivedBytes = 0
            }
        }

        progressSamples[id] = nil
        saveItems()
        task.resume()
    }

    private func resumeTurbo(id: UUID) {
        guard let itemIndex = index(of: id),
              items[itemIndex].transferMode == .turbo,
              let segmentsSnapshot = items[itemIndex].segments,
              !segmentsSnapshot.isEmpty,
              reconstructedRequest(from: items[itemIndex]) != nil,
              TurboPolicy.strongValidator(
                etag: items[itemIndex].responseETag,
                lastModified: items[itemIndex].responseLastModified
              ) != nil
        else {
            fallbackTurboToSingle(id: id, reason: "Turbo resume metadata is unavailable")
            return
        }

        let wasFailed = items[itemIndex].state == .failed

        update(id) { item in
            item.state = .downloading
            item.errorMessage = nil
            item.bytesPerSecond = nil
            item.etaSeconds = nil
            item.rateLimitedUntil = nil

            if item.turboConcurrencyLimit == nil {
                item.turboConcurrencyLimit = min(
                    TurboPolicy.initialConcurrency,
                    segmentsSnapshot.count
                )
            }

            if wasFailed {
                item.turboRateLimitCount = 0

                if var segments = item.segments {
                    for index in segments.indices where !segments[index].completed {
                        segments[index].retryCount = 0
                        segments[index].nextRetryAt = nil
                        segments[index].taskIdentifier = nil
                    }
                    item.segments = segments
                }
            }
        }

        progressSamples[id] = nil
        saveItems()
        launchTurboTasksIfNeeded(id: id)
    }

    private func fallbackTurboToSingle(id: UUID, reason: String) {
        guard let itemIndex = index(of: id), items[itemIndex].transferMode == .turbo else { return }
        guard let request = reconstructedRequest(from: items[itemIndex]) else {
            fail(id: id, message: "Turbo fallback could not reconstruct the original request.", notify: true)
            return
        }

        cancelSegmentTasks(for: id)
        cleanupTurboArtifacts(id: id)

        update(id) {
            $0.transferMode = .single
            $0.segments = nil
            $0.receivedBytes = 0
            $0.taskIdentifier = nil
            $0.resumeDataFile = nil
            $0.turboFallbackReason = reason
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            $0.state = .downloading
        }

        startSingleDownload(itemID: id, request: request, fallbackReason: reason)
    }

    private func reconstructedRequest(from item: DownloadItem) -> URLRequest? {
        guard let url = URL(string: item.sourceURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = item.requestHTTPMethod
        request.allHTTPHeaderFields = item.requestHeaders
        request.allowsCellularAccess = AppSettings.shared.allowCellular
        request.allowsConstrainedNetworkAccess = AppSettings.shared.allowConstrained
        request.allowsExpensiveNetworkAccess = true

        if let body = item.requestBodyBase64 {
            request.httpBody = Data(base64Encoded: body)
        }

        return request
    }

    private func reconnectBackgroundTasks() {
        _ = session
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            for task in tasks {
                guard let identity = TurboTaskDescription.parse(task.taskDescription) else { continue }

                self.taskToItem[task.taskIdentifier] = identity.itemID

                if let segmentIndex = identity.segmentIndex {
                    self.update(identity.itemID) { item in
                        guard var segments = item.segments,
                              let position = segments.firstIndex(where: { $0.index == segmentIndex })
                        else { return }

                        segments[position].taskIdentifier = task.taskIdentifier
                        item.segments = segments
                        item.transferMode = .turbo
                        item.state = .downloading
                        item.bytesPerSecond = nil
                        item.etaSeconds = nil
                    }
                } else {
                    self.update(identity.itemID) {
                        $0.taskIdentifier = task.taskIdentifier
                        $0.transferMode = $0.transferMode ?? .single
                        $0.state = .downloading
                        $0.bytesPerSecond = nil
                        $0.etaSeconds = nil
                    }
                }
            }

            self.saveItems()
        }
    }

    private func cancelTasks(for id: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard let identity = TurboTaskDescription.parse(task.taskDescription),
                      identity.itemID == id
                else { continue }
                task.cancel()
            }
        }
    }

    private func cancelSegmentTasks(for id: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard let identity = TurboTaskDescription.parse(task.taskDescription),
                      identity.itemID == id,
                      identity.segmentIndex != nil
                else { continue }
                task.cancel()
            }
        }
    }

    private func cleanupTurboArtifacts(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            for segment in item.segments ?? [] {
                if let resume = segment.resumeDataFile {
                    try? fileManager.removeItem(at: resumeDirectory.appendingPathComponent(resume))
                }
            }
        }
        try? fileManager.removeItem(at: partsDirectory(for: id))
    }

    private func notifyCompleted(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        DownloadNotificationManager.shared.notifyCompleted(item)
    }

    private func notifyFailed(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        DownloadNotificationManager.shared.notifyFailed(item)
    }

    private func captureResponseMetadata(from task: URLSessionTask, itemID: UUID) {
        guard let response = task.response as? HTTPURLResponse else { return }

        let expectedSHA256: String?
        if response.statusCode == 200 {
            expectedSHA256 = HTTPDigestParser.sha256Base64(
                contentDigest: response.value(forHTTPHeaderField: "Content-Digest"),
                legacyDigest: response.value(forHTTPHeaderField: "Digest")
            )
        } else {
            expectedSHA256 = nil
        }

        let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?
            .lowercased()
            .contains("bytes")

        update(itemID) {
            if $0.responseETag == nil {
                $0.responseETag = response.value(forHTTPHeaderField: "ETag")
            }
            if $0.responseLastModified == nil {
                $0.responseLastModified = response.value(forHTTPHeaderField: "Last-Modified")
            }
            if $0.responseContentEncoding == nil {
                $0.responseContentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")
            }
            if $0.serverAcceptsRanges == nil {
                $0.serverAcceptsRanges = acceptRanges
            }
            if $0.expectedSHA256Base64 == nil {
                $0.expectedSHA256Base64 = expectedSHA256
            }
            if $0.expectedBytes <= 0, response.expectedContentLength > 0, response.statusCode == 200 {
                $0.expectedBytes = response.expectedContentLength
            }
        }
    }

    private func destinationURL(for filename: String) -> URL {
        let sanitized = FilenameResolver.sanitize(filename)
        let base = downloadDirectory.appendingPathComponent(sanitized)

        if !fileManager.fileExists(atPath: base.path) {
            return base
        }

        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent

        for number in 2...9999 {
            let suffix = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let candidate = downloadDirectory.appendingPathComponent(suffix)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return downloadDirectory.appendingPathComponent(UUID().uuidString + "-" + sanitized)
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }

    private func update(_ id: UUID, _ body: (inout DownloadItem) -> Void) {
        guard let index = index(of: id) else { return }
        objectWillChange.send()
        body(&items[index])
    }

    private func saveItems() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            print("Failed to save downloads:", error)
        }
    }

    private func loadItems() {
        guard let data = try? Data(contentsOf: metadataURL) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([DownloadItem].self, from: data)

            for index in items.indices where
                items[index].state == .downloading ||
                items[index].state == .merging ||
                items[index].state == .verifying {
                items[index].state = .paused
                items[index].bytesPerSecond = nil
                items[index].etaSeconds = nil
            }
        } catch {
            print("Failed to load downloads:", error)
        }
    }

    private func identity(for task: URLSessionTask) -> (itemID: UUID, segmentIndex: Int?)? {
        if let parsed = TurboTaskDescription.parse(task.taskDescription) {
            taskToItem[task.taskIdentifier] = parsed.itemID
            return parsed
        }

        if let mapped = taskToItem[task.taskIdentifier] {
            return (mapped, nil)
        }

        return nil
    }

    private func updateSpeed(id: UUID, aggregateBytes: Int64) {
        let now = Date()

        guard let previous = progressSamples[id] else {
            progressSamples[id] = (now, aggregateBytes, 0)
            return
        }

        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed >= 0.25 else { return }

        let deltaBytes = max(0, aggregateBytes - previous.bytes)
        let instant = Double(deltaBytes) / elapsed
        let previousSpeed = previous.speed > 0 ? previous.speed : instant
        let speed = previousSpeed * 0.72 + instant * 0.28
        progressSamples[id] = (now, aggregateBytes, speed)

        guard speed > 0 else { return }

        update(id) {
            $0.bytesPerSecond = speed
            if $0.expectedBytes > aggregateBytes {
                $0.etaSeconds = Double($0.expectedBytes - aggregateBytes) / speed
            } else {
                $0.etaSeconds = nil
            }
        }
    }

    private func fail(id: UUID, message: String, notify: Bool) {
        update(id) {
            $0.state = .failed
            $0.taskIdentifier = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            $0.errorMessage = message
        }
        progressSamples[id] = nil
        saveItems()
        if notify {
            notifyFailed(id: id)
        }
    }

    private func verifyFile(_ url: URL, itemID: UUID) {
        guard let itemIndex = index(of: itemID) else { return }

        let expectedDigest = items[itemIndex].expectedSHA256Base64
        let expectedBytes = items[itemIndex].expectedBytes
        let contentEncoding = items[itemIndex].responseContentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canStrictlyCheckBodyBytes =
            contentEncoding == nil ||
            contentEncoding == "" ||
            contentEncoding == "identity"

        update(itemID) { $0.state = .verifying }
        saveItems()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = Int64(values.fileSize ?? 0)

                if canStrictlyCheckBodyBytes,
                   expectedBytes > 0,
                   fileSize != expectedBytes {
                    try? self.fileManager.removeItem(at: url)
                    DispatchQueue.main.async {
                        self.fail(
                            id: itemID,
                            message: "Integrity check failed: expected \(ByteFormatter.string(expectedBytes)), got \(ByteFormatter.string(fileSize)).",
                            notify: true
                        )
                    }
                    return
                }

                let digest = try FileHasher.sha256Digest(of: url)

                if canStrictlyCheckBodyBytes,
                   let expectedDigest,
                   digest.base64 != expectedDigest {
                    try? self.fileManager.removeItem(at: url)
                    DispatchQueue.main.async {
                        self.update(itemID) {
                            $0.sha256 = digest.hex
                            $0.localRelativePath = nil
                        }
                        self.fail(
                            id: itemID,
                            message: "Integrity check failed: the server SHA-256 does not match the downloaded file.",
                            notify: true
                        )
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.update(itemID) {
                        $0.sha256 = digest.hex
                        if canStrictlyCheckBodyBytes, expectedDigest != nil {
                            $0.integrityStatus = .serverSHA256Verified
                        } else if canStrictlyCheckBodyBytes, expectedBytes > 0, fileSize == expectedBytes {
                            $0.integrityStatus = .sizeVerified
                        } else {
                            $0.integrityStatus = .localSHA256
                        }
                        $0.state = .completed
                        $0.bytesPerSecond = nil
                        $0.etaSeconds = nil
                    }
                    self.cleanupTurboArtifacts(id: itemID)
                    self.saveItems()
                    self.notifyCompleted(id: itemID)
                }
            } catch {
                DispatchQueue.main.async {
                    self.update(itemID) {
                        $0.state = .completed
                        $0.bytesPerSecond = nil
                        $0.etaSeconds = nil
                        $0.errorMessage = "File saved, but SHA-256 calculation failed: " + error.localizedDescription
                    }
                    self.cleanupTurboArtifacts(id: itemID)
                    self.saveItems()
                    self.notifyCompleted(id: itemID)
                }
            }
        }
    }

    private func finishSingleDownload(
        task: URLSessionDownloadTask,
        location: URL,
        itemID: UUID
    ) {
        captureResponseMetadata(from: task, itemID: itemID)

        if let response = task.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            fail(
                id: itemID,
                message: "HTTP \(response.statusCode). The link may have expired or access may be denied.",
                notify: true
            )
            return
        }

        guard let sourceURL = task.originalRequest?.url else {
            fail(id: itemID, message: "The server did not provide a valid source URL.", notify: true)
            return
        }

        let filename = FilenameResolver.filename(for: task.response, fallbackURL: sourceURL)
        let destination = destinationURL(for: filename)

        do {
            try fileManager.moveItem(at: location, to: destination)
            let fileSize = Int64(
                (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )

            update(itemID) {
                $0.filename = destination.lastPathComponent
                $0.localRelativePath = destination.lastPathComponent
                $0.receivedBytes = max($0.receivedBytes, fileSize)
                $0.taskIdentifier = nil
                $0.errorMessage = nil
                $0.bytesPerSecond = nil
                $0.etaSeconds = nil
            }

            if AppSettings.shared.verifyDownloads {
                verifyFile(destination, itemID: itemID)
                return
            }

            guard let itemIndex = index(of: itemID) else { return }
            let contentEncoding = items[itemIndex].responseContentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let canStrictlyCheckBodyBytes =
                contentEncoding == nil ||
                contentEncoding == "" ||
                contentEncoding == "identity"
            let expected = items[itemIndex].expectedBytes

            if canStrictlyCheckBodyBytes, expected > 0, fileSize != expected {
                try? fileManager.removeItem(at: destination)
                update(itemID) { $0.localRelativePath = nil }
                fail(
                    id: itemID,
                    message: "Integrity check failed: downloaded file size is incomplete.",
                    notify: true
                )
            } else {
                update(itemID) {
                    $0.state = .completed
                    $0.integrityStatus =
                        canStrictlyCheckBodyBytes && expected > 0 ? .sizeVerified : nil
                }
                cleanupTurboArtifacts(id: itemID)
                saveItems()
                notifyCompleted(id: itemID)
            }
        } catch {
            fail(
                id: itemID,
                message: "Could not save the file: " + error.localizedDescription,
                notify: true
            )
        }
    }

    private func finishTurboSegment(
        task: URLSessionDownloadTask,
        location: URL,
        itemID: UUID,
        segmentIndex: Int
    ) {
        guard let itemIndex = index(of: itemID),
              items[itemIndex].transferMode == .turbo,
              let segments = items[itemIndex].segments,
              let segment = segments.first(where: { $0.index == segmentIndex })
        else { return }

        guard let response = task.response as? HTTPURLResponse else {
            fallbackTurboToSingle(
                id: itemID,
                reason: "Server returned an invalid range response"
            )
            return
        }

        if response.statusCode == 429 || response.statusCode == 503 {
            handleTurboRateLimit(
                id: itemID,
                segmentIndex: segmentIndex,
                response: response
            )
            return
        }

        guard response.statusCode == 206,
              let range = ContentRangeParser.parse(
                response.value(forHTTPHeaderField: "Content-Range")
              ),
              range.start >= segment.startByte,
              range.start <= segment.endByte,
              range.end == segment.endByte,
              range.total == items[itemIndex].expectedBytes
        else {
            fallbackTurboToSingle(
                id: itemID,
                reason: "Server stopped honoring byte ranges"
            )
            return
        }

        if let expectedETag = items[itemIndex].responseETag,
           let responseETag = response.value(forHTTPHeaderField: "ETag"),
           expectedETag != responseETag {
            fallbackTurboToSingle(
                id: itemID,
                reason: "Remote file changed while downloading"
            )
            return
        }

        let partDirectory = partsDirectory(for: itemID)
        try? fileManager.createDirectory(
            at: partDirectory,
            withIntermediateDirectories: true
        )

        let partName = "segment-\(segmentIndex).part"
        let partURL = partDirectory.appendingPathComponent(partName)
        try? fileManager.removeItem(at: partURL)

        do {
            try fileManager.moveItem(at: location, to: partURL)
            let size = Int64(
                (try? partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )

            guard size == segment.length else {
                try? fileManager.removeItem(at: partURL)

                let retryAttempt = (segment.retryCount ?? 0) + 1
                if retryAttempt <= TurboPolicy.maximumAutomaticRetries {
                    let delay = TurboPolicy.networkRetryDelay(attempt: retryAttempt)
                    let retryAt = Date().addingTimeInterval(delay)

                    update(itemID) { item in
                        guard var currentSegments = item.segments,
                              let position = currentSegments.firstIndex(where: { $0.index == segmentIndex })
                        else { return }

                        currentSegments[position].taskIdentifier = nil
                        currentSegments[position].receivedBytes = 0
                        currentSegments[position].partFile = nil
                        currentSegments[position].resumeDataFile = nil
                        currentSegments[position].retryCount = retryAttempt
                        currentSegments[position].nextRetryAt = retryAt
                        item.segments = currentSegments
                        item.receivedBytes = currentSegments.reduce(0) {
                            $0 + ($1.completed ? $1.length : $1.receivedBytes)
                        }
                        item.errorMessage = nil
                        item.state = .downloading
                    }

                    saveItems()
                    scheduleTurboLaunch(id: itemID, after: delay)
                } else {
                    fallbackTurboToSingle(
                        id: itemID,
                        reason: "Server repeatedly returned incomplete byte ranges"
                    )
                }
                return
            }

            var allCompleted = false

            update(itemID) { item in
                guard var currentSegments = item.segments,
                      let position = currentSegments.firstIndex(where: { $0.index == segmentIndex })
                else { return }

                currentSegments[position].completed = true
                currentSegments[position].receivedBytes = currentSegments[position].length
                currentSegments[position].partFile = partName
                currentSegments[position].taskIdentifier = nil
                currentSegments[position].resumeDataFile = nil
                currentSegments[position].retryCount = 0
                currentSegments[position].nextRetryAt = nil

                item.segments = currentSegments
                item.receivedBytes = currentSegments.reduce(0) {
                    $0 + ($1.completed ? $1.length : $1.receivedBytes)
                }

                if (item.turboRateLimitCount ?? 0) == 0 {
                    let currentLimit = item.turboConcurrencyLimit ?? TurboPolicy.initialConcurrency
                    item.turboConcurrencyLimit = min(
                        currentSegments.count,
                        currentLimit + 1
                    )
                }

                allCompleted = currentSegments.allSatisfy(\.completed)
            }

            saveItems()

            if allCompleted {
                mergeTurboDownload(id: itemID)
            } else {
                launchTurboTasksIfNeeded(id: itemID)
            }
        } catch {
            fail(
                id: itemID,
                message: "Could not save Turbo segment: " + error.localizedDescription,
                notify: true
            )
        }
    }

    private func mergeTurboDownload(id: UUID) {
        guard let itemIndex = index(of: id),
              items[itemIndex].transferMode == .turbo,
              let segments = items[itemIndex].segments,
              !segments.isEmpty,
              segments.allSatisfy(\.completed)
        else { return }

        let itemSnapshot = items[itemIndex]
        let destination = destinationURL(for: itemSnapshot.filename)
        let partsDirectory = partsDirectory(for: id)

        update(id) {
            $0.state = .merging
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
        }
        saveItems()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                try? self.fileManager.removeItem(at: destination)
                self.fileManager.createFile(atPath: destination.path, contents: nil)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }

                for segment in segments.sorted(by: { $0.index < $1.index }) {
                    guard let partFile = segment.partFile else {
                        throw URLError(.cannotOpenFile)
                    }

                    let partURL = partsDirectory.appendingPathComponent(partFile)
                    let input = try FileHandle(forReadingFrom: partURL)

                    while true {
                        let data = try input.read(upToCount: 4 * 1024 * 1024)
                        guard let data, !data.isEmpty else { break }
                        try output.write(contentsOf: data)
                    }

                    try input.close()
                }

                try output.synchronize()

                let finalSize = Int64(
                    (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                )

                guard finalSize == itemSnapshot.expectedBytes else {
                    try? self.fileManager.removeItem(at: destination)
                    DispatchQueue.main.async {
                        self.fail(
                            id: id,
                            message: "Turbo merge failed integrity check: final file size is incorrect.",
                            notify: true
                        )
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.update(id) {
                        $0.filename = destination.lastPathComponent
                        $0.localRelativePath = destination.lastPathComponent
                        $0.receivedBytes = finalSize
                        $0.errorMessage = nil
                    }

                    if AppSettings.shared.verifyDownloads {
                        self.verifyFile(destination, itemID: id)
                    } else {
                        self.update(id) {
                            $0.state = .completed
                            $0.integrityStatus = .sizeVerified
                        }
                        self.cleanupTurboArtifacts(id: id)
                        self.saveItems()
                        self.notifyCompleted(id: id)
                    }
                }
            } catch {
                try? self.fileManager.removeItem(at: destination)
                DispatchQueue.main.async {
                    self.fail(
                        id: id,
                        message: "Turbo merge failed: " + error.localizedDescription,
                        notify: true
                    )
                }
            }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let identity = identity(for: downloadTask),
              let itemIndex = index(of: identity.itemID)
        else { return }

        if let segmentIndex = identity.segmentIndex,
           items[itemIndex].transferMode == .turbo {
            var aggregate: Int64 = 0

            update(identity.itemID) { item in
                guard var segments = item.segments,
                      let position = segments.firstIndex(where: { $0.index == segmentIndex })
                else { return }

                segments[position].receivedBytes = min(
                    segments[position].length,
                    max(0, totalBytesWritten)
                )
                item.segments = segments
                aggregate = segments.reduce(0) {
                    $0 + ($1.completed ? $1.length : $1.receivedBytes)
                }
                item.receivedBytes = aggregate
                item.state = .downloading
            }

            updateSpeed(id: identity.itemID, aggregateBytes: aggregate)
            return
        }

        captureResponseMetadata(from: downloadTask, itemID: identity.itemID)

        update(identity.itemID) {
            $0.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                $0.expectedBytes = totalBytesExpectedToWrite
            }
            if let suggested = downloadTask.response?.suggestedFilename, !suggested.isEmpty {
                $0.filename = FilenameResolver.sanitize(suggested)
            }
            $0.state = .downloading
        }

        updateSpeed(id: identity.itemID, aggregateBytes: totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let identity = identity(for: downloadTask) else { return }
        progressSamples[identity.itemID] = nil

        if let segmentIndex = identity.segmentIndex {
            update(identity.itemID) { item in
                guard var segments = item.segments,
                      let position = segments.firstIndex(where: { $0.index == segmentIndex })
                else { return }

                segments[position].receivedBytes = min(
                    segments[position].length,
                    max(0, fileOffset)
                )
                item.segments = segments
                item.receivedBytes = segments.reduce(0) {
                    $0 + ($1.completed ? $1.length : $1.receivedBytes)
                }
                item.state = .downloading
            }
            return
        }

        update(identity.itemID) {
            $0.receivedBytes = max(0, fileOffset)
            if expectedTotalBytes > 0 {
                $0.expectedBytes = expectedTotalBytes
            }
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            $0.state = .downloading
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let identity = identity(for: downloadTask) else { return }

        if let segmentIndex = identity.segmentIndex {
            finishTurboSegment(
                task: downloadTask,
                location: location,
                itemID: identity.itemID,
                segmentIndex: segmentIndex
            )
        } else {
            finishSingleDownload(
                task: downloadTask,
                location: location,
                itemID: identity.itemID
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let identity = identity(for: task) else { return }

        taskToItem.removeValue(forKey: task.taskIdentifier)

        guard let error else {
            saveItems()
            return
        }

        guard let itemIndex = index(of: identity.itemID) else { return }

        if items[itemIndex].state == .paused {
            return
        }

        let nsError = error as NSError

        if nsError.code == NSURLErrorCancelled {
            return
        }

        if let segmentIndex = identity.segmentIndex {
            guard items[itemIndex].transferMode == .turbo else { return }

            var resumeFile: String?
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                let fileName = identity.itemID.uuidString + "-segment-\(segmentIndex).resume"
                let url = resumeDirectory.appendingPathComponent(fileName)
                if (try? resumeData.write(to: url, options: .atomic)) != nil {
                    resumeFile = fileName
                }
            }

            guard let segmentsSnapshot = items[itemIndex].segments,
                  let segment = segmentsSnapshot.first(where: { $0.index == segmentIndex })
            else { return }

            let attempt = (segment.retryCount ?? 0) + 1

            if attempt > TurboPolicy.maximumAutomaticRetries {
                update(identity.itemID) { item in
                    guard var segments = item.segments,
                          let position = segments.firstIndex(where: { $0.index == segmentIndex })
                    else { return }

                    segments[position].taskIdentifier = nil
                    if let resumeFile {
                        segments[position].resumeDataFile = resumeFile
                    }
                    segments[position].retryCount = attempt
                    item.segments = segments
                }

                fail(
                    id: identity.itemID,
                    message: "Turbo segment failed repeatedly: " + error.localizedDescription,
                    notify: true
                )
                return
            }

            let delay = TurboPolicy.networkRetryDelay(attempt: attempt)
            let retryAt = Date().addingTimeInterval(delay)

            update(identity.itemID) { item in
                guard var segments = item.segments,
                      let position = segments.firstIndex(where: { $0.index == segmentIndex })
                else { return }

                segments[position].taskIdentifier = nil
                segments[position].retryCount = attempt
                segments[position].nextRetryAt = retryAt

                if let resumeFile {
                    segments[position].resumeDataFile = resumeFile
                } else {
                    segments[position].resumeDataFile = nil
                    segments[position].receivedBytes = 0
                }

                item.segments = segments
                item.receivedBytes = segments.reduce(0) {
                    $0 + ($1.completed ? $1.length : $1.receivedBytes)
                }
                item.state = .downloading
                item.bytesPerSecond = nil
                item.etaSeconds = nil
                item.errorMessage = nil
            }

            progressSamples[identity.itemID] = nil
            saveItems()
            scheduleTurboLaunch(id: identity.itemID, after: delay)
            return
        }

        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let fileName = identity.itemID.uuidString + ".resume"
            let url = resumeDirectory.appendingPathComponent(fileName)
            try? resumeData.write(to: url, options: .atomic)
            update(identity.itemID) { $0.resumeDataFile = fileName }
        }

        fail(
            id: identity.itemID,
            message: error.localizedDescription,
            notify: true
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let completion = backgroundCompletionHandler else { return }
        backgroundCompletionHandler = nil
        DispatchQueue.main.async {
            completion()
        }
    }
}
