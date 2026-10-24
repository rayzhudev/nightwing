import Foundation
import CommonCrypto

public actor LyricsModelDownloadService {
    public static let defaultModelDownloadBytes: Int64 = 486_212_372

    public enum DownloadError: Error, LocalizedError, Sendable {
        case unableToCreateApplicationSupportDirectory
        case invalidSourceURL(String)
        case downloadFailed(String)
        case insufficientStorage

        public var errorDescription: String? {
            switch self {
            case .unableToCreateApplicationSupportDirectory:
                return "Could not create the lyrics model folder."
            case .invalidSourceURL(let value):
                return "The lyrics model download address is invalid: \(value)"
            case .downloadFailed(let message):
                return "Could not download the lyrics model: \(message)"
            case .insufficientStorage:
                return "There is not enough free storage to download the lyrics model."
            }
        }
    }

    public struct Manifest: Sendable {
        public var name: String
        public var sourceBaseURL: URL
        public var files: [String]
        public var sha256: [String: String]
        public var expectedFileSizes: [String: Int64]

        public init(
            name: String = "Systran/faster-whisper-small",
            sourceBaseURL: URL = URL(string: "https://huggingface.co/Systran/faster-whisper-small/resolve/536b0662742c02347bc0e980a01041f333bce120")!,
            files: [String] = ["config.json", "model.bin", "tokenizer.json", "vocabulary.txt"],
            sha256: [String: String] = [
                "config.json": "b55496ac7940a7ae47d2c01eab40edfd8701feec1229d9cce3b40014383fb828",
                "model.bin": "3e305921506d8872816023e4c273e75d2419fb89b24da97b4fe7bce14170d671",
                "tokenizer.json": "fb7b63191e9bb045082c79fd742a3106a12c99513ab30df4a0d47fa6cb6fd0ab",
                "vocabulary.txt": "34ce3fe1c5041027b3f8d42912270993f986dbc4bb34cf27f951e34a1e453913"
            ],
            expectedFileSizes: [String: Int64] = [
                "config.json": 2_370,
                "model.bin": 483_546_902,
                "tokenizer.json": 2_203_239,
                "vocabulary.txt": 459_861
            ]
        ) {
            self.name = name
            self.sourceBaseURL = sourceBaseURL
            self.files = files
            self.sha256 = sha256
            self.expectedFileSizes = expectedFileSizes
        }

        public var expectedDownloadBytes: Int64 {
            files.reduce(0) { $0 + (expectedFileSizes[$1] ?? 0) }
        }
    }

    private let manifest: Manifest
    private let directoryURL: URL
    private let huggingFaceCacheURL: URL
    private let fileManager: FileManager
    private var validatedModelURL: URL?
    private var provisioningTask: Task<Void, Never>?
    private var provisioningID: UUID?
    private var provisioningCancellationRequested = false
    private var provisioningProgress: Double?
    private var provisioningWaiters: [UUID: ProvisioningWaiter] = [:]

    private struct ProvisioningWaiter {
        let progress: (@Sendable (Double) -> Void)?
        let continuation: CheckedContinuation<URL, Error>
    }

    public init(
        manifest: Manifest = Manifest(),
        directoryURL: URL,
        huggingFaceCacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.huggingFaceCacheURL = huggingFaceCacheURL ?? Self.defaultHuggingFaceCacheURL(
            for: manifest,
            fileManager: fileManager
        )
        self.fileManager = fileManager
    }

    public static func defaultService(
        applicationName: String = "Nightwing",
        fileManager: FileManager = .default
    ) throws -> LyricsModelDownloadService {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DownloadError.unableToCreateApplicationSupportDirectory
        }

        let directoryURL = applicationSupportURL
            .appendingPathComponent(applicationName, isDirectory: true)
            .appendingPathComponent("TranscriptionModels", isDirectory: true)
            .appendingPathComponent("faster-whisper-small", isDirectory: true)
        return LyricsModelDownloadService(directoryURL: directoryURL, fileManager: fileManager)
    }

    public func localModelDirectory() -> URL {
        directoryURL
    }

    public func availableModelURL() -> URL? {
        if let validatedModelURL,
           (try? validatedModelURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return validatedModelURL
        }

        if let cachedModelURL = huggingFaceCachedModelDirectory() {
            validatedModelURL = cachedModelURL
            return cachedModelURL
        }

        if isModelComplete() {
            validatedModelURL = directoryURL
            return directoryURL
        }

        return nil
    }

    public func ensureModelAvailable(progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        if let validatedModelURL = availableModelURL() {
            progress?(1)
            return validatedModelURL
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                provisioningWaiters[waiterID] = ProvisioningWaiter(
                    progress: progress,
                    continuation: continuation
                )
                if let provisioningProgress {
                    progress?(provisioningProgress)
                }
                if provisioningTask == nil {
                    startProvisioning()
                }
            }
        } onCancel: {
            Task {
                await self.cancelProvisioningWaiter(id: waiterID)
            }
        }
    }

    private func startProvisioning() {
        guard provisioningTask == nil, !provisioningWaiters.isEmpty else { return }

        let provisioningID = UUID()
        self.provisioningID = provisioningID
        provisioningCancellationRequested = false
        provisioningProgress = nil
        provisioningTask = Task {
            let result: Result<URL, Error>
            do {
                result = .success(try await provisionModel(id: provisioningID))
            } catch {
                result = .failure(Task.isCancelled ? CancellationError() : error)
            }
            finishProvisioning(id: provisioningID, result: result)
        }
    }

    private func cancelProvisioningWaiter(id: UUID) {
        guard let waiter = provisioningWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())

        guard provisioningWaiters.isEmpty, provisioningTask != nil else { return }
        provisioningCancellationRequested = true
        provisioningTask?.cancel()
    }

    private func finishProvisioning(id: UUID, result: Result<URL, Error>) {
        guard provisioningID == id else { return }

        provisioningTask = nil
        provisioningID = nil
        provisioningProgress = nil

        if provisioningCancellationRequested,
           case .failure(let error) = result,
           error is CancellationError {
            provisioningCancellationRequested = false
            if !provisioningWaiters.isEmpty {
                startProvisioning()
            }
            return
        }

        provisioningCancellationRequested = false
        if case .success(let url) = result {
            validatedModelURL = url
        }

        let waiters = Array(provisioningWaiters.values)
        provisioningWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
    }

    private func reportProvisioningProgress(_ value: Double, id: UUID) {
        guard provisioningID == id else { return }
        let clampedValue = min(max(value, 0), 1)
        let monotonicValue = max(provisioningProgress ?? 0, clampedValue)
        provisioningProgress = monotonicValue
        for waiter in provisioningWaiters.values {
            waiter.progress?(monotonicValue)
        }
    }

    private func provisionModel(id provisioningID: UUID) async throws -> URL {
        try Task.checkCancellation()

        if let cachedModelURL = huggingFaceCachedModelDirectory() {
            reportProvisioningProgress(1, id: provisioningID)
            return cachedModelURL
        }

        if isModelComplete() {
            reportProvisioningProgress(1, id: provisioningID)
            return directoryURL
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let values = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity < 600_000_000 {
            throw DownloadError.insufficientStorage
        }

        let expectedDownloadBytes = max(manifest.expectedDownloadBytes, 1)
        var completedExpectedBytes: Int64 = 0
        for fileName in manifest.files {
            try Task.checkCancellation()
            let destinationURL = directoryURL.appendingPathComponent(fileName)
            let expectedFileBytes = manifest.expectedFileSizes[fileName] ?? 0
            if isValidModelFile(at: destinationURL, named: fileName) {
                completedExpectedBytes += expectedFileBytes
                reportProvisioningProgress(
                    Double(completedExpectedBytes) / Double(expectedDownloadBytes),
                    id: provisioningID
                )
                continue
            }

            let completedBeforeFile = completedExpectedBytes
            try await download(fileName: fileName, to: destinationURL) { fileProgress in
                Task {
                    await self.reportProvisioningProgress(
                        Double(completedBeforeFile) / Double(expectedDownloadBytes) +
                            fileProgress * Double(expectedFileBytes) / Double(expectedDownloadBytes),
                        id: provisioningID
                    )
                }
            }
            try Task.checkCancellation()
            completedExpectedBytes += expectedFileBytes
            reportProvisioningProgress(
                Double(completedExpectedBytes) / Double(expectedDownloadBytes),
                id: provisioningID
            )
        }
        guard isModelComplete() else {
            throw DownloadError.downloadFailed("One or more model files failed their integrity check.")
        }
        reportProvisioningProgress(1, id: provisioningID)
        return directoryURL
    }

    private static func defaultHuggingFaceCacheURL(for manifest: Manifest, fileManager: FileManager) -> URL {
        let cacheFolderName = "models--" + manifest.name.replacingOccurrences(of: "/", with: "--")
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return homeURL
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(cacheFolderName, isDirectory: true)
    }

    private func huggingFaceCachedModelDirectory() -> URL? {
        if let mainSnapshotURL = huggingFaceMainSnapshotURL(),
           isModelComplete(in: mainSnapshotURL) {
            return mainSnapshotURL
        }

        let snapshotsURL = huggingFaceCacheURL.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURLs = try? fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return snapshotURLs.first { snapshotURL in
            guard let values = try? snapshotURL.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                return false
            }
            return isModelComplete(in: snapshotURL)
        }
    }

    private func huggingFaceMainSnapshotURL() -> URL? {
        let mainRefURL = huggingFaceCacheURL
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("main")
        guard let snapshotID = try? String(contentsOf: mainRefURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshotID.isEmpty else {
            return nil
        }

        return huggingFaceCacheURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
    }

    private func isModelComplete() -> Bool {
        isModelComplete(in: directoryURL)
    }

    private func isModelComplete(in directoryURL: URL) -> Bool {
        manifest.files.allSatisfy {
            isValidModelFile(at: directoryURL.appendingPathComponent($0), named: $0)
        }
    }

    private func isValidModelFile(at url: URL, named fileName: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        guard fileSize.int64Value > 0 else { return false }
        guard let expectedHash = manifest.sha256[fileName] else { return true }
        return Self.sha256(of: url) == expectedHash
    }

    private static func sha256(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            CC_SHA256_Update(&context, buffer, CC_LONG(count))
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func download(
        fileName: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let sourceURL = manifest.sourceBaseURL.appendingPathComponent(fileName)
        guard sourceURL.scheme == "https" else {
            throw DownloadError.invalidSourceURL(sourceURL.absoluteString)
        }

        let partialURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(fileName).download")
        do {
            if fileManager.fileExists(atPath: partialURL.path) {
                try fileManager.removeItem(at: partialURL)
            }
            let response = try await ModelFileDownloader.download(
                from: sourceURL,
                to: partialURL,
                progress: progress
            )
            try Task.checkCancellation()
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw DownloadError.downloadFailed("HTTP \(httpResponse.statusCode) for \(fileName).")
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: partialURL, to: destinationURL)
            guard isValidModelFile(at: destinationURL, named: fileName) else {
                try? fileManager.removeItem(at: destinationURL)
                throw DownloadError.downloadFailed("Integrity verification failed for \(fileName).")
            }
        } catch let error as DownloadError {
            try? fileManager.removeItem(at: partialURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: partialURL)
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw DownloadError.downloadFailed(error.localizedDescription)
        }
    }
}

private final class ModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse?, Error>?
    private var resultError: Error?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    private init(destinationURL: URL, progress: (@Sendable (Double) -> Void)?) {
        self.destinationURL = destinationURL
        self.progress = progress
    }

    static func download(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URLResponse? {
        let delegate = ModelFileDownloader(destinationURL: destinationURL, progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                delegate.start(from: sourceURL, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func start(
        from sourceURL: URL,
        continuation: CheckedContinuation<URLResponse?, Error>
    ) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: sourceURL)

        lock.lock()
        self.continuation = continuation
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()

        task.resume()
        if shouldCancel {
            task.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            resultError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error = error ?? resultError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: task.response)
        }
        session.finishTasksAndInvalidate()
    }
}
