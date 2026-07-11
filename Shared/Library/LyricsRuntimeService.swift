import Foundation
import CommonCrypto

#if os(macOS)
public actor LyricsRuntimeService {
    public enum RuntimeError: Error, LocalizedError, Sendable {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let message): return "Could not prepare the transcription engine: \(message)"
            }
        }
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let preferredPythonPath: String?
    private var resolvedPythonPath: String?
    private var provisioningTask: Task<Void, Never>?
    private var provisioningID: UUID?
    private var provisioningCancellationRequested = false
    private var provisioningProgress: String?
    private var provisioningWaiters: [UUID: ProvisioningWaiter] = [:]

    private struct ProvisioningWaiter {
        let progress: (@Sendable (String) -> Void)?
        let continuation: CheckedContinuation<String, Error>
    }

    public init(directoryURL: URL, preferredPythonPath: String? = nil, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.preferredPythonPath = preferredPythonPath
        self.fileManager = fileManager
    }

    public static func defaultService(preferredPythonPath: String? = nil, fileManager: FileManager = .default) throws -> LyricsRuntimeService {
        guard let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RuntimeError.unavailable("Application Support is unavailable.")
        }
        return LyricsRuntimeService(
            directoryURL: supportURL.appendingPathComponent("Nightwing/TranscriptionRuntime", isDirectory: true),
            preferredPythonPath: preferredPythonPath,
            fileManager: fileManager
        )
    }

    public func pythonPath(progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        if let resolvedPythonPath,
           fileManager.isExecutableFile(atPath: resolvedPythonPath) {
            return resolvedPythonPath
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
            let result: Result<String, Error>
            do {
                result = .success(try await provisionPythonPath())
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

    private func finishProvisioning(id: UUID, result: Result<String, Error>) {
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
        if case .success(let path) = result {
            resolvedPythonPath = path
        }

        let waiters = Array(provisioningWaiters.values)
        provisioningWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
    }

    private func reportProvisioningProgress(_ message: String) {
        provisioningProgress = message
        for waiter in provisioningWaiters.values {
            waiter.progress?(message)
        }
    }

    private func provisionPythonPath() async throws -> String {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let managedPython = directoryURL.appendingPathComponent("venv/bin/python").path
        let candidates = [
            preferredPythonPath,
            managedPython,
            NSHomeDirectory() + "/OpenClaw/venvs/video-editing/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            try Task.checkCancellation()
            if try await supportsFasterWhisper(candidate) {
                return candidate
            }
        }

        reportProvisioningProgress("Downloading transcription engine...")
        let uvPath = try await ensureUV()
        try await run(uvPath, ["--no-config", "venv", "--python", "3.12", "--managed-python", directoryURL.appendingPathComponent("venv").path])
        reportProvisioningProgress("Installing transcription engine...")
        try await run(uvPath, [
            "--no-config",
            "pip", "install",
            "--python", managedPython,
            "--default-index", "https://pypi.org/simple",
            "--exclude-newer", "2026-07-11",
            "faster-whisper==1.2.1"
        ])
        guard try await supportsFasterWhisper(managedPython) else {
            throw RuntimeError.unavailable("The installed engine could not be loaded.")
        }
        return managedPython
    }

    private func supportsFasterWhisper(_ path: String) async throws -> Bool {
        do {
            try await run(path, ["-c", "import faster_whisper"])
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private func ensureUV() async throws -> String {
        let version = "0.11.16"
        #if arch(arm64)
        let archiveName = "uv-aarch64-apple-darwin.tar.gz"
        let expectedArchiveSHA256 = "2b25be1af546be330b340b0a76b99f989daa6d92678fdffb87438e661e9d88fb"
        #elseif arch(x86_64)
        let archiveName = "uv-x86_64-apple-darwin.tar.gz"
        let expectedArchiveSHA256 = "6b91ae3de155f51bd1f5b74814821c79f016a176561f252cd9ddfb976939af2e"
        #else
        throw RuntimeError.unavailable("This Mac architecture is not supported by the runtime bootstrap.")
        #endif

        // Version the bootstrap directory so a binary installed by an older,
        // weaker verification path is never silently reused.
        let executableURL = directoryURL.appendingPathComponent("uv-\(version)/uv")
        if fileManager.isExecutableFile(atPath: executableURL.path) { return executableURL.path }

        let sourceURL = URL(string: "https://github.com/astral-sh/uv/releases/download/\(version)/\(archiveName)")!
        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RuntimeError.unavailable("The runtime bootstrap download failed.")
        }
        let archiveURL = directoryURL.appendingPathComponent(archiveName)
        try? fileManager.removeItem(at: archiveURL)
        try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        guard Self.sha256(of: archiveURL) == expectedArchiveSHA256 else {
            try? fileManager.removeItem(at: archiveURL)
            throw RuntimeError.unavailable("The runtime bootstrap failed its integrity check.")
        }
        let extractionURL = directoryURL.appendingPathComponent("uv-extracted", isDirectory: true)
        try? fileManager.removeItem(at: extractionURL)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", ["-xzf", archiveURL.path, "-C", extractionURL.path])
        guard let found = fileManager.enumerator(at: extractionURL, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == "uv" && fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw RuntimeError.unavailable("The runtime bootstrap archive was invalid.")
        }
        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: executableURL)
        try fileManager.copyItem(at: found, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try? fileManager.removeItem(at: archiveURL)
        try? fileManager.removeItem(at: extractionURL)
        return executableURL.path
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "PIP_EXTRA_INDEX_URL", "PIP_FIND_LINKS", "PIP_INDEX_URL",
            "PYTHONHOME", "PYTHONPATH",
            "UV_DEFAULT_INDEX", "UV_EXTRA_INDEX_URL", "UV_FIND_LINKS", "UV_INDEX", "UV_INDEX_URL"
        ] {
            environment[key] = nil
        }
        process.environment = environment
        let logURL = directoryURL.appendingPathComponent("runtime-install.log")
        guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
            throw RuntimeError.unavailable("Could not create the runtime log.")
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
        }
        process.standardOutput = log
        process.standardError = log
        try process.run()

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw CancellationError()
        }

        try log.synchronize()
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            throw RuntimeError.unavailable(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
}
#endif
