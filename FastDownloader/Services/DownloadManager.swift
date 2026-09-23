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
        configuration.httpMaximumConnectionsPerHost = 6
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

    private var downloadDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func createDirectoriesIfNeeded() {
        try? fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
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
            state: .downloading,
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestHTTPMethod: request.httpMethod ?? "GET",
            requestBodyBase64: request.httpBody?.base64EncodedString()
        )

        items.insert(item, at: 0)
        let task = session.downloadTask(with: request)
        task.taskDescription = item.id.uuidString
        taskToItem[task.taskIdentifier] = item.id
        update(item.id) {
            $0.taskIdentifier = task.taskIdentifier
        }
        saveItems()
        task.resume()
    }

    func pause(id: UUID) {
        guard let index = index(of: id), items[index].state == .downloading else { return }
        update(id) {
            $0.state = .paused
            $0.errorMessage = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
        }
        progressSamples[id] = nil
        saveItems()

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            guard let task = tasks.first(where: { $0.taskDescription == id.uuidString }) as? URLSessionDownloadTask else {
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
                        self.update(id) {
                            $0.resumeDataFile = fileName
                        }
                        self.saveItems()
                    } catch {
                        self.update(id) {
                            $0.errorMessage = "Could not save resume data: " + error.localizedDescription
                        }
                        self.saveItems()
                    }
                }
            })
        }
    }

    func resume(id: UUID) {
        guard let index = index(of: id) else { return }
        let item = items[index]
        guard item.state == .paused || item.state == .failed else { return }

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
            update(id) {
                $0.state = .failed
                $0.errorMessage = "The original request can no longer be reconstructed."
            }
            saveItems()
            return
        }

        task.taskDescription = id.uuidString
        taskToItem[task.taskIdentifier] = id
        update(id) {
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

    func retry(id: UUID) {
        guard let index = index(of: id) else { return }
        let item = items[index]
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
        resume(id: id)
    }

    func delete(id: UUID) {
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == id.uuidString })?.cancel()
        }

        if let item = items.first(where: { $0.id == id }) {
            if let relative = item.localRelativePath {
                try? fileManager.removeItem(at: downloadDirectory.appendingPathComponent(relative))
            }
            if let resume = item.resumeDataFile {
                try? fileManager.removeItem(at: resumeDirectory.appendingPathComponent(resume))
            }
        }

        items.removeAll { $0.id == id }
        saveItems()
    }

    func localURL(for item: DownloadItem) -> URL? {
        guard let relative = item.localRelativePath else { return nil }
        let url = downloadDirectory.appendingPathComponent(relative)
        return fileManager.fileExists(atPath: url.path) ? url : nil
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
                guard
                    let description = task.taskDescription,
                    let id = UUID(uuidString: description)
                else { continue }

                self.taskToItem[task.taskIdentifier] = id
                self.update(id) {
                    $0.taskIdentifier = task.taskIdentifier
                    if $0.state != .paused {
                        $0.state = .downloading
                    }
                    $0.bytesPerSecond = nil
                    $0.etaSeconds = nil
                }
            }
            self.saveItems()
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
            for index in items.indices where items[index].state == .downloading || items[index].state == .verifying {
                items[index].state = .paused
            }
        } catch {
            print("Failed to load downloads:", error)
        }
    }

    private func itemID(for task: URLSessionTask) -> UUID? {
        if let mapped = taskToItem[task.taskIdentifier] {
            return mapped
        }
        if let description = task.taskDescription, let id = UUID(uuidString: description) {
            taskToItem[task.taskIdentifier] = id
            return id
        }
        return nil
    }

    private func verifyFile(_ url: URL, itemID: UUID) {
        update(itemID) { $0.state = .verifying }
        saveItems()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let hash = try FileHasher.sha256(of: url)
                DispatchQueue.main.async {
                    self?.update(itemID) {
                        $0.sha256 = hash
                        $0.state = .completed
                        $0.bytesPerSecond = nil
                        $0.etaSeconds = nil
                    }
                    self?.saveItems()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.update(itemID) {
                        $0.state = .completed
                        $0.bytesPerSecond = nil
                        $0.etaSeconds = nil
                        $0.errorMessage = "File saved, but SHA-256 verification failed: " + error.localizedDescription
                    }
                    self?.saveItems()
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
        guard let id = itemID(for: downloadTask) else { return }

        let now = Date()
        var smoothedSpeed: Double?
        if let previous = progressSamples[id] {
            let elapsed = now.timeIntervalSince(previous.date)
            if elapsed >= 0.25 {
                let deltaBytes = max(0, totalBytesWritten - previous.bytes)
                let instant = Double(deltaBytes) / elapsed
                let previousSpeed = previous.speed > 0 ? previous.speed : instant
                let speed = previousSpeed * 0.72 + instant * 0.28
                smoothedSpeed = speed
                progressSamples[id] = (now, totalBytesWritten, speed)
            }
        } else {
            progressSamples[id] = (now, totalBytesWritten, 0)
        }

        update(id) {
            $0.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                $0.expectedBytes = totalBytesExpectedToWrite
            }
            if let smoothedSpeed, smoothedSpeed > 0 {
                $0.bytesPerSecond = smoothedSpeed
                if $0.expectedBytes > totalBytesWritten {
                    $0.etaSeconds = Double($0.expectedBytes - totalBytesWritten) / smoothedSpeed
                } else {
                    $0.etaSeconds = nil
                }
            }
            if let suggested = downloadTask.response?.suggestedFilename, !suggested.isEmpty {
                $0.filename = FilenameResolver.sanitize(suggested)
            }
            $0.state = .downloading
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let id = itemID(for: downloadTask) else { return }
        progressSamples[id] = nil
        update(id) {
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
        guard let id = itemID(for: downloadTask) else { return }

        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            update(id) {
                $0.state = .failed
                $0.errorMessage = "HTTP \(response.statusCode). The link may have expired or access may be denied."
                $0.taskIdentifier = nil
                $0.bytesPerSecond = nil
                $0.etaSeconds = nil
            }
            saveItems()
            return
        }

        guard let sourceURL = downloadTask.originalRequest?.url else {
            update(id) {
                $0.state = .failed
                $0.errorMessage = "The server did not provide a valid source URL."
                $0.bytesPerSecond = nil
                $0.etaSeconds = nil
            }
            saveItems()
            return
        }

        let filename = FilenameResolver.filename(for: downloadTask.response, fallbackURL: sourceURL)
        let destination = destinationURL(for: filename)

        do {
            try fileManager.moveItem(at: location, to: destination)
            update(id) {
                $0.filename = destination.lastPathComponent
                $0.localRelativePath = destination.lastPathComponent
                $0.receivedBytes = max($0.receivedBytes, Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                $0.taskIdentifier = nil
                $0.errorMessage = nil
                $0.bytesPerSecond = nil
                $0.etaSeconds = nil
            }

            if AppSettings.shared.verifyDownloads {
                verifyFile(destination, itemID: id)
            } else {
                update(id) {
                    $0.state = .completed
                    $0.bytesPerSecond = nil
                    $0.etaSeconds = nil
                }
                saveItems()
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.errorMessage = "Could not save the file: " + error.localizedDescription
                $0.taskIdentifier = nil
                $0.bytesPerSecond = nil
                $0.etaSeconds = nil
            }
            saveItems()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let id = itemID(for: task) else { return }
        taskToItem.removeValue(forKey: task.taskIdentifier)
        progressSamples[id] = nil

        guard let error else {
            saveItems()
            return
        }

        if let index = index(of: id), items[index].state == .paused {
            return
        }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            return
        }

        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let fileName = id.uuidString + ".resume"
            let url = resumeDirectory.appendingPathComponent(fileName)
            try? resumeData.write(to: url, options: .atomic)
            update(id) { $0.resumeDataFile = fileName }
        }

        update(id) {
            $0.state = .failed
            $0.taskIdentifier = nil
            $0.bytesPerSecond = nil
            $0.etaSeconds = nil
            $0.errorMessage = error.localizedDescription
        }
        saveItems()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let completion = backgroundCompletionHandler else { return }
        backgroundCompletionHandler = nil
        DispatchQueue.main.async {
            completion()
        }
    }
}
