import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(os)
import os
#endif

private struct InFlightAlbumDownload {
    let token: UUID
    let task: Task<URL, Error>
    let stagingDirectory: URL
}

actor YtDlpDownloadService {
    private static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let maxSearchCacheEntries = 24
    private static let downloadRetryDelaysNanoseconds: [UInt64] = [0, 700_000_000, 1_800_000_000]
    private static let albumPreviewTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let youTubeMusicClientContextCache = YouTubeMusicClientContextCache()
    private let store = OnlineTrackStore()
    #if canImport(os)
    private let logger = Logger(subsystem: "com.nightwing", category: "YtDlp")
    #endif
    private let maxConcurrentDownloads = 2
    private var activeDownloads = 0
    private var inFlightTrackDownloads: [String: Task<URL, Error>] = [:]
    private var inFlightAlbumDownloads: [String: InFlightAlbumDownload] = [:]
    private var trackSearchCache: [String: [OnlineSearchResult]] = [:]
    private var albumSearchCache: [String: [OnlineAlbumSearchResult]] = [:]
    private var trackSearchCacheOrder: [String] = []
    private var albumSearchCacheOrder: [String] = []

    func search(query: String) async throws -> [OnlineSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let cacheKey = Self.normalizedSearchCacheKey(trimmedQuery)
        if let cachedResults = trackSearchCache[cacheKey] {
            return cachedResults
        }

        let musicCandidates: [YouTubeSearchCandidate]
        do {
            musicCandidates = try await Self.fetchYouTubeMusicCandidates(query: trimmedQuery)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            #if canImport(os)
            logger.info("YouTube Music song search failed; using YouTube fallback: \(error.localizedDescription, privacy: .public)")
            #endif
            musicCandidates = []
        }
        if !musicCandidates.isEmpty {
            let results = Self.rankedResults(from: musicCandidates, query: trimmedQuery)
            cacheTrackSearchResults(results, for: cacheKey)
            return results
        }

        async let officialAudioCandidates = Self.fetchYouTubeCandidates(query: "\(trimmedQuery) official audio", sourceBias: 40)
        async let broadCandidates = Self.fetchYouTubeCandidates(query: trimmedQuery, sourceBias: 0)

        let candidates = try await officialAudioCandidates + broadCandidates
        let results = Self.rankedResults(from: candidates, query: trimmedQuery)
        cacheTrackSearchResults(results, for: cacheKey)
        return results
    }

    func searchAlbums(query: String) async throws -> [OnlineAlbumSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let cacheKey = Self.normalizedSearchCacheKey(trimmedQuery)
        if let cachedResults = albumSearchCache[cacheKey] {
            return cachedResults
        }

        let musicAlbums: [YouTubeAlbumCandidate]
        do {
            musicAlbums = try await Self.fetchYouTubeMusicAlbumCandidates(query: trimmedQuery)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            #if canImport(os)
            logger.info("YouTube Music album search failed; using YouTube fallback: \(error.localizedDescription, privacy: .public)")
            #endif
            musicAlbums = []
        }
        if !musicAlbums.isEmpty {
            let results = Self.rankedAlbumResults(from: musicAlbums, query: trimmedQuery)
            cacheAlbumSearchResults(results, for: cacheKey)
            return results
        }

        async let albumCandidates = Self.fetchYouTubeAlbumCandidates(query: "\(trimmedQuery) album", sourceBias: 30)
        async let broadCandidates = Self.fetchYouTubeAlbumCandidates(query: trimmedQuery, sourceBias: 0)

        let results = Self.rankedAlbumResults(from: try await albumCandidates + broadCandidates, query: trimmedQuery)
        cacheAlbumSearchResults(results, for: cacheKey)
        return results
    }

    func download(
        _ track: OnlineSearchResult,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let ytDlpPaths = Self.locateYtDlpCandidates()
        guard !ytDlpPaths.isEmpty else {
            throw YtDlpError.notFound
        }

        let sourceHash = OnlineTrackStore.hashKey(for: track.sourceURL)
        if let cached = try resolveCachedTrack(sourceHash: sourceHash),
           FileManager.default.fileExists(atPath: cached.localFileURL) {
            progressHandler?(1)
            return URL(fileURLWithPath: cached.localFileURL)
        }

        if let inFlightDownload = inFlightTrackDownloads[sourceHash] {
            let fileURL = try await inFlightDownload.value
            progressHandler?(1)
            return fileURL
        }

        while activeDownloads >= maxConcurrentDownloads {
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        // Another request for the same source may have started or completed
        // while this one was waiting for a download slot.
        if let cached = try resolveCachedTrack(sourceHash: sourceHash),
           FileManager.default.fileExists(atPath: cached.localFileURL) {
            progressHandler?(1)
            return URL(fileURLWithPath: cached.localFileURL)
        }
        if let inFlightDownload = inFlightTrackDownloads[sourceHash] {
            let fileURL = try await inFlightDownload.value
            progressHandler?(1)
            return fileURL
        }

        activeDownloads += 1
        defer {
            activeDownloads -= 1
            inFlightTrackDownloads[sourceHash] = nil
        }

        let downloadsDir = Self.onlineTrackDirectory(sourceHash: sourceHash)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let extensionName = preferredAudioExtension(for: track)
        let outputTemplate = downloadsDir
            .appendingPathComponent("\(sourceHash).%(ext)s")
            .path

        #if canImport(os)
        logger.info("Downloading \(track.title, privacy: .public)")
        #endif

        let downloadTask = Task {
            try await Self.downloadTrackWithFallbacks(
                executables: ytDlpPaths,
                directArguments: Self.directAudioDownloadArguments(
                    format: Self.preferredAudioFormat(for: track),
                    outputTemplate: outputTemplate,
                    sourceURL: track.sourceURL
                ),
                extractedArguments: Self.extractedAudioDownloadArguments(
                    extensionName: extensionName,
                    outputTemplate: outputTemplate,
                    sourceURL: track.sourceURL
                ),
                expectedFileURL: downloadsDir.appendingPathComponent("\(sourceHash).\(extensionName)"),
                progressHandler: progressHandler
            )
        }
        inFlightTrackDownloads[sourceHash] = downloadTask
        let localFileURL = try await downloadTask.value

        let cached = CachedTrackEntry(
            id: track.id,
            title: track.title,
            artist: track.artist,
            duration: track.duration,
            sourceURL: track.sourceURL.absoluteString,
            sourceHash: sourceHash,
            localFileURL: localFileURL.path,
            thumbnailURL: track.thumbnailURL?.absoluteString,
            cachedAt: Date()
        )
        try store.upsert(cached)
        progressHandler?(1)

        return localFileURL
    }

    func downloadAlbum(
        _ album: OnlineAlbumSearchResult,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let ytDlpPaths = Self.locateYtDlpCandidates()
        guard !ytDlpPaths.isEmpty else {
            throw YtDlpError.notFound
        }

        let sourceHash = OnlineTrackStore.hashKey(for: album.sourceURL)
        let albumDir = Self.onlineAlbumDirectory(sourceHash: sourceHash, title: album.title)
        if let existingAlbumDir = Self.existingUsableAlbumDirectory(at: albumDir) {
            progressHandler?(1)
            return existingAlbumDir
        }

        if let inFlightDownload = inFlightAlbumDownloads[sourceHash] {
            let folderURL = try await inFlightDownload.task.value
            progressHandler?(1)
            return folderURL
        }

        while activeDownloads >= maxConcurrentDownloads {
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        if let existingAlbumDir = Self.existingUsableAlbumDirectory(at: albumDir) {
            progressHandler?(1)
            return existingAlbumDir
        }
        if let inFlightDownload = inFlightAlbumDownloads[sourceHash] {
            let folderURL = try await inFlightDownload.task.value
            progressHandler?(1)
            return folderURL
        }

        activeDownloads += 1
        let token = UUID()
        let stagingDirectory = Self.temporaryAlbumDirectory(sourceHash: sourceHash)
        defer {
            activeDownloads -= 1
            if inFlightAlbumDownloads[sourceHash]?.token == token {
                inFlightAlbumDownloads[sourceHash] = nil
            }
            try? FileManager.default.removeItem(at: stagingDirectory)
        }

        let downloadTask = Task {
            try await Self.downloadAlbumWithRetries(
                executables: ytDlpPaths,
                album: album,
                stagingDirectory: stagingDirectory,
                finalDirectory: albumDir,
                progressHandler: progressHandler
            )
        }
        inFlightAlbumDownloads[sourceHash] = InFlightAlbumDownload(
            token: token,
            task: downloadTask,
            stagingDirectory: stagingDirectory
        )

        let folderURL = try await downloadTask.value
        progressHandler?(1)
        return folderURL
    }

    /// Stops an active album download and removes its incomplete staging files.
    /// The final album directory is never removed, so an already completed
    /// download remains available in the library.
    func cancelAlbumDownload(_ album: OnlineAlbumSearchResult) {
        let sourceHash = OnlineTrackStore.hashKey(for: album.sourceURL)
        guard let inFlightDownload = inFlightAlbumDownloads[sourceHash] else { return }
        inFlightDownload.task.cancel()
        try? FileManager.default.removeItem(at: inFlightDownload.stagingDirectory)
    }

    /// Returns related tracks suitable for extending a queue that was started
    /// from a single online result. Results never include the seed track.
    func suggestedTracks(after seed: OnlineSearchResult, limit: Int = 12) async throws -> [OnlineSearchResult] {
        let query = seed.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty, limit > 0 else { return [] }
        let seedHash = OnlineTrackStore.hashKey(for: seed.sourceURL)
        return try await search(query: query)
            .filter { OnlineTrackStore.hashKey(for: $0.sourceURL) != seedHash }
            .prefix(limit)
            .map { $0 }
    }

    /// Loads a lightweight album track listing without downloading audio.
    /// `yt-dlp --flat-playlist` works for both regular YouTube playlists and
    /// YouTube Music album playlist IDs, giving the UI a browsable preview.
    func albumTracks(for album: OnlineAlbumSearchResult) async throws -> [OnlineSearchResult] {
        let executables = Self.locateYtDlpCandidates()
        guard !executables.isEmpty else {
            throw YtDlpError.notFound
        }

        var output: String?
        var lastError: Error?
        for executable in executables {
            do {
                output = try await Self.runCommand(
                    executable: executable,
                    arguments: ["--ignore-config", "--flat-playlist", "--dump-single-json", "--no-warnings", album.sourceURL.absoluteString],
                    timeoutNanoseconds: Self.albumPreviewTimeoutNanoseconds
                )
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        guard let output else {
            throw lastError ?? YtDlpError.commandFailed("The album track list could not be read.")
        }
        guard let data = output.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = payload["entries"] as? [[String: Any]] else {
            throw YtDlpError.commandFailed("The album track list could not be read.")
        }

        return entries.compactMap { entry in
            guard let videoID = entry["id"] as? String,
                  !videoID.isEmpty else { return nil }
            let rawTitle = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle?.isEmpty == false ? rawTitle! : "Unknown Track"
            let artist = (entry["artist"] as? String)
                ?? (entry["uploader"] as? String)
                ?? album.artist
            let duration = (entry["duration"] as? NSNumber)?.doubleValue
            let thumbnail = (entry["thumbnail"] as? String).flatMap(URL.init(string:)) ?? album.thumbnailURL
            return OnlineSearchResult(
                id: videoID,
                title: title,
                artist: artist,
                duration: duration,
                sourceURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)")!,
                thumbnailURL: thumbnail
            )
        }
    }

    func existingAlbumDirectory(for album: OnlineAlbumSearchResult) -> URL? {
        let sourceHash = OnlineTrackStore.hashKey(for: album.sourceURL)
        let albumDir = Self.onlineAlbumDirectory(sourceHash: sourceHash, title: album.title)
        return Self.existingUsableAlbumDirectory(at: albumDir)
    }

    func getCachedEntry(sourceHash: String) throws -> CachedTrackEntry? {
        try resolveCachedTrack(sourceHash: sourceHash)
    }

    func getAllCachedEntries() throws -> [CachedTrackEntry] {
        try store.loadCachedTracks()
    }

    func removeCachedEntry(localFileURL: URL) throws -> CachedTrackEntry? {
        try store.remove(localFileURL: localFileURL)
    }

    func existingThumbnailURL(for track: OnlineSearchResult) -> URL? {
        let sourceHash = OnlineTrackStore.hashKey(for: track.sourceURL)
        let downloadsDir = Self.onlineTrackDirectory(sourceHash: sourceHash)
        return Self.existingThumbnailURL(in: downloadsDir)
    }

    func ensureThumbnail(for track: OnlineSearchResult) async throws -> URL? {
        let sourceHash = OnlineTrackStore.hashKey(for: track.sourceURL)
        let downloadsDir = Self.onlineTrackDirectory(sourceHash: sourceHash)
        if let existingURL = Self.existingThumbnailURL(in: downloadsDir) {
            return existingURL
        }

        for thumbnailURL in Self.thumbnailCandidates(for: track) {
            if let savedURL = try? await Self.downloadThumbnail(thumbnailURL, to: downloadsDir) {
                return savedURL
            }
        }

        if let ytDlpPath = Self.locateYtDlp(),
           let savedURL = try? await Self.downloadThumbnailWithYtDlp(
            executable: ytDlpPath,
            sourceURL: track.sourceURL,
            to: downloadsDir
           ) {
            return savedURL
        }

        return Self.existingThumbnailURL(in: downloadsDir)
    }

    static func locateYtDlp() -> String? {
        locateYtDlpCandidates().first
    }

    static func locateYtDlpCandidates() -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        if let bundleURL = bundledYtDlpURL() {
            if let preparedURL = prepareBundledYtDlp(from: bundleURL) {
                appendExecutableCandidate(preparedURL.path, to: &candidates, seen: &seen)
            }
            if candidates.isEmpty {
                appendExecutableCandidate(bundleURL.path, to: &candidates, seen: &seen)
            }
            // The bundled helper and its prepared copy are the same version.
            // Retrying both (then an older system install) only repeats failures.
            if !candidates.isEmpty { return candidates }
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.components(separatedBy: ":") {
                let candidate = (dir as NSString).appendingPathComponent("yt-dlp")
                appendExecutableCandidate(candidate, to: &candidates, seen: &seen)
            }
        }

        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] {
            appendExecutableCandidate(path, to: &candidates, seen: &seen)
        }

        return candidates
    }

    private static func bundledYtDlpURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "yt-dlp", withExtension: nil),
           FileManager.default.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }

        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp"),
           FileManager.default.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }

        return nil
    }

    private static func prepareBundledYtDlp(from bundleURL: URL) -> URL? {
        guard let destinationURL = helperDestinationURL() else { return nil }
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let shouldCopy = !fileManager.contentsEqual(atPath: destinationURL.path, andPath: bundleURL.path)

            if shouldCopy {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: bundleURL, to: destinationURL)
            }

            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
            removeLaunchBlockingExtendedAttributes(from: destinationURL)

            guard fileManager.isExecutableFile(atPath: destinationURL.path) else { return nil }
            return destinationURL
        } catch {
            #if canImport(os)
            Logger(subsystem: "com.nightwing", category: "YtDlp").error("Could not prepare yt-dlp helper: \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    private static func helperDestinationURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nightwing")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("yt-dlp")
    }

    private static func appendExecutableCandidate(_ path: String, to candidates: inout [String], seen: inout Set<String>) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !seen.contains(standardizedPath),
              FileManager.default.isExecutableFile(atPath: standardizedPath) else {
            return
        }

        seen.insert(standardizedPath)
        candidates.append(standardizedPath)
    }

    private static func removeLaunchBlockingExtendedAttributes(from url: URL) {
        #if os(macOS)
        for attribute in ["com.apple.quarantine", "com.apple.provenance"] {
            url.path.withCString { pathPointer in
                attribute.withCString { attributePointer in
                    _ = removexattr(pathPointer, attributePointer, 0)
                }
            }
        }
        #endif
    }

    static func downloadsBaseURL() -> URL {
        onlineDownloadsBaseURL()
    }

    static func onlineDownloadsBaseURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return directory.appendingPathComponent("Nightwing").appendingPathComponent("Online Downloads")
    }

    private static func onlineTrackDirectory(sourceHash: String) -> URL {
        onlineDownloadsBaseURL()
            .appendingPathComponent("Tracks")
            .appendingPathComponent(sourceHash)
    }

    private static func onlineAlbumDirectory(sourceHash: String, title: String) -> URL {
        onlineDownloadsBaseURL()
            .appendingPathComponent("Albums")
            .appendingPathComponent("\(safeFileName(title))-\(sourceHash)")
    }

    private static func temporaryAlbumDirectory(sourceHash: String) -> URL {
        onlineDownloadsBaseURL()
            .appendingPathComponent("Albums")
            .appendingPathComponent(".staging-\(sourceHash)-\(UUID().uuidString)")
    }

    private static func existingUsableAlbumDirectory(at directory: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let audioFiles = (try? audioFileURLs(in: directory)) ?? []
        return audioFiles.isEmpty ? nil : directory
    }

    private static func replaceIncompleteAlbumDirectory(with stagingDirectory: URL, finalDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: finalDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.removeItem(at: finalDirectory)
        }

        try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
    }

    private func resolveCachedTrack(sourceHash: String) throws -> CachedTrackEntry? {
        let entries = try store.loadCachedTracks()
        return entries.first { $0.sourceHash == sourceHash }
    }

    private func cacheTrackSearchResults(_ results: [OnlineSearchResult], for key: String) {
        trackSearchCache[key] = results
        trackSearchCacheOrder.removeAll { $0 == key }
        trackSearchCacheOrder.append(key)
        while trackSearchCacheOrder.count > Self.maxSearchCacheEntries {
            let removedKey = trackSearchCacheOrder.removeFirst()
            trackSearchCache[removedKey] = nil
        }
    }

    private func cacheAlbumSearchResults(_ results: [OnlineAlbumSearchResult], for key: String) {
        albumSearchCache[key] = results
        albumSearchCacheOrder.removeAll { $0 == key }
        albumSearchCacheOrder.append(key)
        while albumSearchCacheOrder.count > Self.maxSearchCacheEntries {
            let removedKey = albumSearchCacheOrder.removeFirst()
            albumSearchCache[removedKey] = nil
        }
    }

    private static func normalizedSearchCacheKey(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func preferredAudioExtension(for track: OnlineSearchResult) -> String {
        switch track.provider {
        case .youtube:
            return "m4a"
        case .soundcloud:
            return "mp3"
        }
    }

    private static func preferredAudioFormat(for track: OnlineSearchResult) -> String {
        switch track.provider {
        case .youtube:
            return "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"
        case .soundcloud:
            return "bestaudio[ext=mp3]/bestaudio[ext=m4a]"
        }
    }

    private static func directAudioDownloadArguments(format: String, outputTemplate: String, sourceURL: URL) -> [String] {
        [
            "--ignore-config",
            "--newline",
            "--no-playlist",
            "--no-mtime",
            "--retries", "3",
            "--fragment-retries", "3",
            "--concurrent-fragments", "4",
            "--format", format,
            "--output", outputTemplate,
            sourceURL.absoluteString
        ]
    }

    private static func extractedAudioDownloadArguments(extensionName: String, outputTemplate: String, sourceURL: URL) -> [String] {
        [
            "--ignore-config",
            "--newline",
            "--no-playlist",
            "--no-mtime",
            "--retries", "3",
            "--fragment-retries", "3",
            "--concurrent-fragments", "4",
            "--format", "bestaudio/best",
            "--extract-audio",
            "--audio-format", extensionName,
            "--audio-quality", "0",
            "--output", outputTemplate,
            sourceURL.absoluteString
        ]
    }

    private static func albumDownloadArguments(outputTemplate: String, sourceURL: URL) -> [String] {
        [
            "--ignore-config",
            "--newline",
            "--yes-playlist",
            "--ignore-errors",
            "--no-mtime",
            "--retries", "3",
            "--fragment-retries", "3",
            "--concurrent-fragments", "4",
            "--format", "bestaudio/best",
            "--extract-audio",
            "--audio-format", "m4a",
            "--audio-quality", "0",
            "--output", outputTemplate,
            sourceURL.absoluteString
        ]
    }

    private static func downloadTrackWithFallbacks(
        executables: [String],
        directArguments: [String],
        extractedArguments: [String],
        expectedFileURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var lastError: Error?

        for (attempt, delay) in downloadRetryDelaysNanoseconds.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }

            for executable in executables {
                do {
                    return try await downloadWithProgress(
                        executable: executable,
                        arguments: directArguments,
                        expectedFileURL: expectedFileURL,
                        progressHandler: progressHandler
                    )
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    lastError = error

                    #if canImport(os)
                    Logger(subsystem: "com.nightwing", category: "YtDlp").error("Direct download attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    #endif
                }

                do {
                    return try await downloadWithProgress(
                        executable: executable,
                        arguments: extractedArguments,
                        expectedFileURL: expectedFileURL,
                        progressHandler: progressHandler
                    )
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    lastError = error

                    #if canImport(os)
                    Logger(subsystem: "com.nightwing", category: "YtDlp").error("Extracted download attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    #endif
                }
            }
        }

        throw lastError ?? YtDlpError.downloadFailed("No audio file was downloaded.")
    }

    private static func downloadAlbumWithRetries(
        executables: [String],
        album: OnlineAlbumSearchResult,
        stagingDirectory: URL,
        finalDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var lastError: Error?

        for (attempt, delay) in downloadRetryDelaysNanoseconds.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }

            for executable in executables {
                try? FileManager.default.removeItem(at: stagingDirectory)
                do {
                    let folderURL = try await downloadAlbumOnce(
                        executable: executable,
                        album: album,
                        stagingDirectory: stagingDirectory,
                        finalDirectory: finalDirectory,
                        progressHandler: progressHandler
                    )
                    return folderURL
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        try? FileManager.default.removeItem(at: stagingDirectory)
                        throw CancellationError()
                    }
                    lastError = error
                    try? FileManager.default.removeItem(at: stagingDirectory)

                    #if canImport(os)
                    Logger(subsystem: "com.nightwing", category: "YtDlp").error("Album download attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    #endif
                }
            }
        }

        throw lastError ?? YtDlpError.downloadFailed("No album tracks were downloaded.")
    }

    private static func downloadAlbumOnce(
        executable: String,
        album: OnlineAlbumSearchResult,
        stagingDirectory: URL,
        finalDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        _ = try? await downloadThumbnail(album.thumbnailURL, to: stagingDirectory)

        let outputTemplate = stagingDirectory
            .appendingPathComponent("%(playlist_index)02d - %(title).180B.%(ext)s")
            .path

        do {
            try await runDownloadProcess(
                executable: executable,
                arguments: albumDownloadArguments(outputTemplate: outputTemplate, sourceURL: album.sourceURL),
                progressHandler: progressHandler
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            let partialAudioFiles = (try? audioFileURLs(in: stagingDirectory)) ?? []
            guard !partialAudioFiles.isEmpty else {
                throw error
            }
        }

        let audioFiles = try audioFileURLs(in: stagingDirectory)
        guard !audioFiles.isEmpty else {
            throw YtDlpError.downloadFailed("No album tracks were downloaded.")
        }

        try replaceIncompleteAlbumDirectory(with: stagingDirectory, finalDirectory: finalDirectory)
        return finalDirectory
    }

    private static func downloadWithProgress(
        executable: String,
        arguments: [String],
        expectedFileURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let execution = try await executeProcess(
            executable: executable,
            arguments: arguments,
            aggregatesPlaylistProgress: false,
            progressHandler: progressHandler
        )

        guard execution.terminationStatus == 0 else {
            throw YtDlpError.downloadFailed(diagnosticMessage(from: execution.output))
        }

        if FileManager.default.fileExists(atPath: expectedFileURL.path) {
            return expectedFileURL
        }

        let baseName = expectedFileURL.deletingPathExtension().lastPathComponent
        let directory = expectedFileURL.deletingLastPathComponent()
        let matches = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
        if let fileURL = matches.first(where: { $0.deletingPathExtension().lastPathComponent == baseName }) {
            return fileURL
        }

        throw YtDlpError.downloadFailed("Downloaded file was not found.")
    }

    private static func runDownloadProcess(
        executable: String,
        arguments: [String],
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let execution = try await executeProcess(
            executable: executable,
            arguments: arguments,
            aggregatesPlaylistProgress: true,
            progressHandler: progressHandler
        )

        // --ignore-errors can exit successfully even when every playlist item
        // failed. Preserve the actual extractor error before inspecting files.
        guard execution.terminationStatus == 0, !execution.output.contains("ERROR:") else {
            throw YtDlpError.downloadFailed(diagnosticMessage(from: execution.output))
        }
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> String {
        let execution = try await executeProcess(
            executable: executable,
            arguments: arguments,
            aggregatesPlaylistProgress: false,
            progressHandler: nil,
            timeoutNanoseconds: timeoutNanoseconds,
            maximumOutputBytes: nil
        )

        guard execution.terminationStatus == 0 else {
            throw YtDlpError.commandFailed(execution.output.isEmpty ? executable : execution.output)
        }

        return execution.output
    }

    private static func executeProcess(
        executable: String,
        arguments: [String],
        aggregatesPlaylistProgress: Bool,
        progressHandler: (@Sendable (Double) -> Void)?,
        timeoutNanoseconds: UInt64? = nil,
        maximumOutputBytes: Int? = 128 * 1_024
    ) async throws -> ProcessExecutionResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = downloaderRuntimeArguments() + arguments
        // Finder-launched apps do not inherit the user's shell PATH. Also make
        // ffmpeg/ffprobe available for audio extraction and album downloads.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = downloaderSearchDirectories().joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw YtDlpError.launchFailed(error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()

        let control = ProcessExecutionControl(process: process, readHandle: pipe.fileHandleForReading)
        let readerTask = Task.detached(priority: .utility) {
            var output = Data()
            var pendingLine = ""
            var progressEmitter = ProgressEmitter(aggregatesPlaylistProgress: aggregatesPlaylistProgress)
            let handle = pipe.fileHandleForReading

            while true {
                let data: Data
                do {
                    guard let nextData = try handle.read(upToCount: 64 * 1_024),
                          !nextData.isEmpty else { break }
                    data = nextData
                } catch {
                    break
                }
                Self.appendProcessOutput(data, to: &output, maximumBytes: maximumOutputBytes)

                guard progressHandler != nil else { continue }
                pendingLine.append(String(decoding: data, as: UTF8.self))
                while let newline = pendingLine.firstIndex(where: { $0.isNewline }) {
                    let line = String(pendingLine[..<newline])
                    pendingLine.removeSubrange(...newline)
                    progressEmitter.consume(line, to: progressHandler)
                }
            }

            if !pendingLine.isEmpty {
                progressEmitter.consume(pendingLine, to: progressHandler)
            }
            process.waitUntilExit()

            return ProcessExecutionResult(
                output: String(decoding: output, as: UTF8.self),
                terminationStatus: process.terminationStatus
            )
        }

        let timeoutTask: Task<Void, Never>? = timeoutNanoseconds.map { timeout in
            Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(nanoseconds: timeout)
                    control.stop(reason: .timedOut)
                } catch {
                    return
                }
            }
        }
        defer { timeoutTask?.cancel() }

        return try await withTaskCancellationHandler {
            let result = await readerTask.value
            switch control.stopReason {
            case .some(.cancelled):
                throw CancellationError()
            case .some(.timedOut):
                throw YtDlpError.commandTimedOut
            case .none:
                try Task.checkCancellation()
                return result
            }
        } onCancel: {
            control.stop(reason: .cancelled)
        }
    }

    private static func appendProcessOutput(_ data: Data, to output: inout Data, maximumBytes: Int?) {
        output.append(data)
        if let maximumBytes, output.count > maximumBytes {
            output.removeFirst(output.count - maximumBytes)
        }
    }

    static func downloaderSearchDirectories() -> [String] {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":").filter { !$0.isEmpty }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deno/bin").path]
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    static func downloaderRuntimeArguments() -> [String] {
        // yt-dlp only enables Deno by default. Enable an installed supported
        // runtime explicitly and use an absolute path for GUI launches.
        for runtime in ["deno", "node"] {
            for directory in downloaderSearchDirectories() {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(runtime).path
                if FileManager.default.isExecutableFile(atPath: path) {
                    return ["--js-runtimes", "\(runtime):\(path)"]
                }
            }
        }
        return []
    }

    static func diagnosticMessage(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Playlist completion/progress lines often follow the real error.
        return lines.last(where: { $0.contains("ERROR:") })
            ?? lines.last(where: { $0.hasPrefix("WARNING:") })
            ?? lines.last ?? "Unknown error"
    }

    private static func fetchYouTubeCandidates(query: String, sourceBias: Int) async throws -> [YouTubeSearchCandidate] {
        guard let initialData = try await fetchYouTubeInitialData(query: query) else {
            return []
        }

        var renderers: [[String: Any]] = []
        collectVideoRenderers(from: initialData, into: &renderers)

        return renderers
            .prefix(24)
            .enumerated()
            .compactMap { index, renderer in
                candidate(from: renderer, sourceBias: sourceBias, searchPosition: index)
            }
    }

    private static func fetchYouTubeMusicCandidates(query: String) async throws -> [YouTubeSearchCandidate] {
        guard let initialData = try await fetchYouTubeMusicInitialData(query: query) else { return [] }

        var renderers: [[String: Any]] = []
        collectMusicResponsiveListItemRenderers(from: initialData, into: &renderers)

        return renderers
            .prefix(32)
            .enumerated()
            .compactMap { index, renderer in
                musicSongCandidate(from: renderer, searchPosition: index)
            }
    }

    private static func fetchYouTubeAlbumCandidates(query: String, sourceBias: Int) async throws -> [YouTubeAlbumCandidate] {
        guard let initialData = try await fetchYouTubeInitialData(query: query) else {
            return []
        }

        var playlistRenderers: [[String: Any]] = []
        var lockupRenderers: [[String: Any]] = []
        collectPlaylistRenderers(from: initialData, into: &playlistRenderers)
        collectLockupViewModels(from: initialData, into: &lockupRenderers)

        let playlistCandidates = playlistRenderers
            .prefix(16)
            .enumerated()
            .compactMap { index, renderer in
                albumCandidate(fromPlaylistRenderer: renderer, sourceBias: sourceBias, searchPosition: index)
            }

        let lockupCandidates = lockupRenderers
            .prefix(16)
            .enumerated()
            .compactMap { index, renderer in
                albumCandidate(fromLockupViewModel: renderer, sourceBias: sourceBias, searchPosition: index + playlistCandidates.count)
            }

        return playlistCandidates + lockupCandidates
    }

    private static func fetchYouTubeMusicAlbumCandidates(query: String) async throws -> [YouTubeAlbumCandidate] {
        guard let initialData = try await fetchYouTubeMusicInitialData(query: query) else { return [] }

        var renderers: [[String: Any]] = []
        collectMusicResponsiveListItemRenderers(from: initialData, into: &renderers)

        return renderers
            .prefix(32)
            .enumerated()
            .compactMap { index, renderer in
                musicAlbumCandidate(from: renderer, searchPosition: index)
            }
    }

    private static func fetchYouTubeMusicInitialData(query: String) async throws -> [String: Any]? {
        var pageComponents = URLComponents(string: "https://music.youtube.com/search")!
        pageComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let pageURL = pageComponents.url else { return nil }

        guard let context = try await youTubeMusicClientContext(for: pageURL) else {
            return nil
        }

        var searchComponents = URLComponents(string: "https://music.youtube.com/youtubei/v1/search")!
        searchComponents.queryItems = [URLQueryItem(name: "key", value: context.apiKey)]
        guard let searchURL = searchComponents.url else { return nil }

        let regionCode: String
        if #available(macOS 13.0, *) {
            regionCode = Locale.current.region?.identifier ?? "US"
        } else {
            regionCode = Locale.current.regionCode ?? "US"
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": context.clientVersion,
                    "hl": "en",
                    "gl": regionCode
                ]
            ],
            "query": query
        ]

        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue(chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func youTubeMusicClientContext(for pageURL: URL) async throws -> YouTubeMusicClientContext? {
        if let cachedContext = await Self.youTubeMusicClientContextCache.freshContext() {
            return cachedContext
        }

        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue(chromeUserAgent, forHTTPHeaderField: "User-Agent")
        pageRequest.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (pageData, _) = try await URLSession.shared.data(for: pageRequest)
        guard let html = String(data: pageData, encoding: .utf8),
              let apiKey = quotedValue(after: #""INNERTUBE_API_KEY":""#, in: html),
              let clientVersion = quotedValue(after: #""INNERTUBE_CLIENT_VERSION":""#, in: html) else {
            return nil
        }

        let context = YouTubeMusicClientContext(
            apiKey: apiKey,
            clientVersion: clientVersion,
            fetchedAt: Date()
        )
        await Self.youTubeMusicClientContextCache.store(context)
        return context
    }

    private static func fetchYouTubeInitialData(query: String) async throws -> [String: Any]? {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query)
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return initialDataObject(from: html)
    }

    private static func rankedResults(from candidates: [YouTubeSearchCandidate], query: String) -> [OnlineSearchResult] {
        let queryTokens = tokenSet(query)
        let wantsRemix = containsAny(query, terms: ["remix", "edit", "version", "cover", "live", "acoustic", "piano"])
        var bestByVideoID: [String: YouTubeSearchCandidate] = [:]

        for candidate in candidates {
            guard candidate.duration.map({ $0 >= 60 && $0 <= 600 }) ?? true else { continue }
            let scoredCandidate = candidate.scored(queryTokens: queryTokens, wantsRemix: wantsRemix)
            if let existing = bestByVideoID[candidate.id] {
                bestByVideoID[candidate.id] = scoredCandidate.score > existing.score ? scoredCandidate : existing
            } else {
                bestByVideoID[candidate.id] = scoredCandidate
            }
        }

        let sortedCandidates = bestByVideoID.values.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.searchPosition < $1.searchPosition
        }

        var selectedCandidates: [YouTubeSearchCandidate] = []
        var selectedEntityKeys = Set<String>()
        for candidate in sortedCandidates {
            let baseKey = canonicalSongKey(candidate.title)
            let artistKey = canonicalArtistKey(candidate.channel)
            let entityKey = "\(baseKey)|\(artistKey)"
            let isMeaningfulVariant = wantsRemix || containsAny(candidate.title, terms: ["remix", "acoustic", "piano", "orchestration"])
            if selectedEntityKeys.contains(entityKey), !isMeaningfulVariant {
                continue
            }
            selectedEntityKeys.insert(entityKey)
            selectedCandidates.append(candidate)
            if selectedCandidates.count >= 24 { break }
        }

        return selectedCandidates.map { candidate in
            OnlineSearchResult(
                id: candidate.id,
                title: displayTitle(candidate.title),
                artist: candidate.channel,
                duration: candidate.duration,
                sourceURL: URL(string: "https://www.youtube.com/watch?v=\(candidate.id)")!,
                thumbnailURL: candidate.thumbnailURL
            )
        }
    }

    private static func rankedAlbumResults(from candidates: [YouTubeAlbumCandidate], query: String) -> [OnlineAlbumSearchResult] {
        let queryTokens = tokenSet(query)
        var bestByID: [String: YouTubeAlbumCandidate] = [:]

        for candidate in candidates {
            let scoredCandidate = candidate.scored(queryTokens: queryTokens)
            if let existing = bestByID[candidate.id] {
                bestByID[candidate.id] = scoredCandidate.score > existing.score ? scoredCandidate : existing
            } else {
                bestByID[candidate.id] = scoredCandidate
            }
        }

        return bestByID.values
            .filter { !$0.id.hasPrefix("RD") && !$0.title.localizedCaseInsensitiveContains("mix - ") }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.searchPosition < $1.searchPosition
            }
            .prefix(4)
            .map { candidate in
                OnlineAlbumSearchResult(
                    id: candidate.id,
                    title: displayAlbumTitle(candidate.title),
                    artist: candidate.artist,
                    detailText: candidate.detailText,
                    sourceURL: URL(string: "https://www.youtube.com/playlist?list=\(candidate.id)")!,
                    thumbnailURL: candidate.thumbnailURL
                )
            }
    }

    private static func initialDataObject(from html: String) -> [String: Any]? {
        guard let markerRange = html.range(of: "var ytInitialData = ") else { return nil }
        let jsonStart = markerRange.upperBound
        guard let scriptEnd = html[jsonStart...].range(of: ";</script>")?.lowerBound else { return nil }
        let jsonString = String(html[jsonStart..<scriptEnd])
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func quotedValue(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(text[valueStart..<valueEnd])
    }

    private static func collectVideoRenderers(from value: Any, into renderers: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if let renderer = dictionary["videoRenderer"] as? [String: Any] {
                renderers.append(renderer)
            }
            for child in dictionary.values {
                collectVideoRenderers(from: child, into: &renderers)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectVideoRenderers(from: child, into: &renderers)
            }
        }
    }

    private static func collectPlaylistRenderers(from value: Any, into renderers: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if let renderer = dictionary["playlistRenderer"] as? [String: Any] {
                renderers.append(renderer)
            }
            for child in dictionary.values {
                collectPlaylistRenderers(from: child, into: &renderers)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectPlaylistRenderers(from: child, into: &renderers)
            }
        }
    }

    private static func collectLockupViewModels(from value: Any, into renderers: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if let renderer = dictionary["lockupViewModel"] as? [String: Any],
               renderer["contentType"] as? String == "LOCKUP_CONTENT_TYPE_PLAYLIST" {
                renderers.append(renderer)
            }
            for child in dictionary.values {
                collectLockupViewModels(from: child, into: &renderers)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectLockupViewModels(from: child, into: &renderers)
            }
        }
    }

    private static func collectMusicResponsiveListItemRenderers(from value: Any, into renderers: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if let renderer = dictionary["musicResponsiveListItemRenderer"] as? [String: Any] {
                renderers.append(renderer)
            }
            for child in dictionary.values {
                collectMusicResponsiveListItemRenderers(from: child, into: &renderers)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectMusicResponsiveListItemRenderers(from: child, into: &renderers)
            }
        }
    }

    private static func candidate(from renderer: [String: Any], sourceBias: Int, searchPosition: Int) -> YouTubeSearchCandidate? {
        guard let id = renderer["videoId"] as? String,
              let title = text(from: renderer["title"]) else {
            return nil
        }

        let channel = text(from: renderer["longBylineText"]) ?? text(from: renderer["ownerText"])
        let duration = duration(from: renderer["lengthText"])
        let viewCount = viewCount(from: renderer["viewCountText"])
        let thumbnailURL = thumbnailURL(fromRenderer: renderer)
        let isVerifiedArtist = ownerBadges(from: renderer).contains {
            $0.localizedCaseInsensitiveContains("Official Artist") || $0.localizedCaseInsensitiveContains("Verified")
        }

        return YouTubeSearchCandidate(
            id: id,
            title: title,
            channel: channel,
            duration: duration,
            viewCount: viewCount,
            thumbnailURL: thumbnailURL,
            isVerifiedArtist: isVerifiedArtist,
            searchPosition: searchPosition,
            sourceBias: sourceBias
        )
    }

    private static func musicSongCandidate(from renderer: [String: Any], searchPosition: Int) -> YouTubeSearchCandidate? {
        let columns = musicFlexColumnTexts(from: renderer)
        guard columns.count >= 2,
              columns[1].localizedCaseInsensitiveContains("Song"),
              let id = firstVideoID(in: renderer) else {
            return nil
        }

        let title = columns[0]
        let artist = musicMetadataParts(from: columns[1]).dropFirst().first
        let playsText = columns.dropFirst(2).first

        return YouTubeSearchCandidate(
            id: id,
            title: title,
            channel: artist,
            duration: nil,
            viewCount: playCount(from: playsText),
            thumbnailURL: musicThumbnailURL(from: renderer),
            isVerifiedArtist: true,
            searchPosition: searchPosition,
            sourceBias: 90
        )
    }

    private static func albumCandidate(fromPlaylistRenderer renderer: [String: Any], sourceBias: Int, searchPosition: Int) -> YouTubeAlbumCandidate? {
        guard let id = renderer["playlistId"] as? String,
              !id.hasPrefix("RD"),
              let title = text(from: renderer["title"]) else {
            return nil
        }

        return YouTubeAlbumCandidate(
            id: id,
            title: title,
            artist: text(from: renderer["shortBylineText"]) ?? text(from: renderer["longBylineText"]),
            detailText: text(from: renderer["videoCountText"]),
            thumbnailURL: thumbnailURL(fromRenderer: renderer),
            searchPosition: searchPosition,
            sourceBias: sourceBias
        )
    }

    private static func musicAlbumCandidate(from renderer: [String: Any], searchPosition: Int) -> YouTubeAlbumCandidate? {
        let columns = musicFlexColumnTexts(from: renderer)
        guard columns.count >= 2,
              columns[1].localizedCaseInsensitiveContains("Album"),
              let id = firstPlaylistID(in: renderer) ?? firstBrowseID(in: renderer) else {
            return nil
        }

        let metadataParts = musicMetadataParts(from: columns[1])
        let artist = metadataParts.dropFirst().first { !$0.allSatisfy(\.isNumber) }

        return YouTubeAlbumCandidate(
            id: id,
            title: columns[0],
            artist: artist,
            detailText: columns[1],
            thumbnailURL: musicThumbnailURL(from: renderer),
            searchPosition: searchPosition,
            sourceBias: 80
        )
    }

    private static func albumCandidate(fromLockupViewModel renderer: [String: Any], sourceBias: Int, searchPosition: Int) -> YouTubeAlbumCandidate? {
        guard let id = renderer["contentId"] as? String,
              !id.hasPrefix("RD"),
              let metadata = renderer["metadata"] as? [String: Any],
              let lockupMetadata = metadata["lockupMetadataViewModel"] as? [String: Any],
              let title = contentString(from: lockupMetadata["title"]) else {
            return nil
        }

        let metadataRows = (((lockupMetadata["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]]) ?? []
        let rowTexts = metadataRows.flatMap { row -> [String] in
            let parts = row["metadataParts"] as? [[String: Any]] ?? []
            return parts.compactMap { contentString(from: $0["text"]) }
        }

        return YouTubeAlbumCandidate(
            id: id,
            title: title,
            artist: rowTexts.first,
            detailText: rowTexts.dropFirst().first,
            thumbnailURL: thumbnailURL(fromLockupViewModel: renderer),
            searchPosition: searchPosition,
            sourceBias: sourceBias
        )
    }

    private static func text(from value: Any?) -> String? {
        if let dictionary = value as? [String: Any] {
            if let simpleText = dictionary["simpleText"] as? String {
                return simpleText
            }
            if let runs = dictionary["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                return joined.isEmpty ? nil : joined
            }
        }
        return nil
    }

    private static func musicFlexColumnTexts(from renderer: [String: Any]) -> [String] {
        guard let columns = renderer["flexColumns"] as? [[String: Any]] else { return [] }
        return columns.compactMap { column in
            let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
            return text(from: renderer?["text"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    private static func musicMetadataParts(from text: String) -> [String] {
        text
            .components(separatedBy: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func firstVideoID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let watchEndpoint = dictionary["watchEndpoint"] as? [String: Any],
               let videoID = watchEndpoint["videoId"] as? String {
                return videoID
            }
            for child in dictionary.values {
                if let videoID = firstVideoID(in: child) {
                    return videoID
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let videoID = firstVideoID(in: child) {
                    return videoID
                }
            }
        }
        return nil
    }

    private static func firstPlaylistID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let watchEndpoint = dictionary["watchEndpoint"] as? [String: Any],
               let playlistID = watchEndpoint["playlistId"] as? String {
                return playlistID
            }
            if let playlistID = dictionary["playlistId"] as? String {
                return playlistID
            }
            for child in dictionary.values {
                if let playlistID = firstPlaylistID(in: child) {
                    return playlistID
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let playlistID = firstPlaylistID(in: child) {
                    return playlistID
                }
            }
        }
        return nil
    }

    private static func firstBrowseID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let browseEndpoint = dictionary["browseEndpoint"] as? [String: Any],
               let browseID = browseEndpoint["browseId"] as? String,
               browseID.hasPrefix("OLAK5") {
                return browseID
            }
            for child in dictionary.values {
                if let browseID = firstBrowseID(in: child) {
                    return browseID
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let browseID = firstBrowseID(in: child) {
                    return browseID
                }
            }
        }
        return nil
    }

    private static func contentString(from value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary["content"] as? String ?? text(from: value)
    }

    private static func duration(from value: Any?) -> TimeInterval? {
        guard let text = text(from: value) else { return nil }
        let parts = text.split(separator: ":").compactMap { TimeInterval($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func viewCount(from value: Any?) -> Int? {
        guard let text = text(from: value) else { return nil }
        let digits = text.filter(\.isNumber)
        return Int(digits)
    }

    private static func playCount(from text: String?) -> Int? {
        guard let text else { return nil }
        let lowerText = text.lowercased()
        let numberText = lowerText
            .replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
        guard let number = Double(numberText) else { return nil }

        if lowerText.contains("b") {
            return Int(number * 1_000_000_000)
        }
        if lowerText.contains("m") {
            return Int(number * 1_000_000)
        }
        if lowerText.contains("k") {
            return Int(number * 1_000)
        }
        return Int(number)
    }

    private static func thumbnailURL(fromRenderer renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]] else {
            return nil
        }

        return thumbnails
            .compactMap { thumbnail -> (url: URL, width: Int, height: Int)? in
                guard let urlString = thumbnail["url"] as? String,
                      let url = URL(string: urlString) else {
                    return nil
                }

                let width = thumbnail["width"] as? Int ?? 0
                let height = thumbnail["height"] as? Int ?? 0
                return (url, width, height)
            }
            .sorted { lhs, rhs in
                lhs.width * lhs.height > rhs.width * rhs.height
            }
            .first?
            .url
    }

    private static func thumbnailURL(fromLockupViewModel renderer: [String: Any]) -> URL? {
        guard let contentImage = renderer["contentImage"] as? [String: Any] else { return nil }
        var sources: [[String: Any]] = []
        collectThumbnailSources(from: contentImage, into: &sources)
        return largestThumbnailURL(from: sources)
    }

    private static func musicThumbnailURL(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any] else { return nil }
        var sources: [[String: Any]] = []
        collectThumbnailSources(from: thumbnail, into: &sources)
        return largestThumbnailURL(from: sources)
    }

    private static func collectThumbnailSources(from value: Any, into sources: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if let sourceArray = dictionary["sources"] as? [[String: Any]] {
                sources.append(contentsOf: sourceArray)
            }
            if let thumbnailArray = dictionary["thumbnails"] as? [[String: Any]] {
                sources.append(contentsOf: thumbnailArray)
            }
            for child in dictionary.values {
                collectThumbnailSources(from: child, into: &sources)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectThumbnailSources(from: child, into: &sources)
            }
        }
    }

    private static func largestThumbnailURL(from thumbnails: [[String: Any]]) -> URL? {
        thumbnails
            .compactMap { thumbnail -> (url: URL, width: Int, height: Int)? in
                guard let urlString = thumbnail["url"] as? String,
                      let url = URL(string: urlString) else {
                    return nil
                }

                let width = thumbnail["width"] as? Int ?? 0
                let height = thumbnail["height"] as? Int ?? 0
                return (url, width, height)
            }
            .sorted { lhs, rhs in
                lhs.width * lhs.height > rhs.width * rhs.height
            }
            .first?
            .url
    }

    private static func ownerBadges(from renderer: [String: Any]) -> [String] {
        guard let badges = renderer["ownerBadges"] as? [[String: Any]] else { return [] }
        return badges.compactMap { badge in
            guard let metadataBadge = badge["metadataBadgeRenderer"] as? [String: Any] else { return nil }
            return metadataBadge["tooltip"] as? String
                ?? ((metadataBadge["accessibilityData"] as? [String: Any])?["label"] as? String)
        }
    }

    private static func canonicalSongKey(_ title: String) -> String {
        var normalized = title.lowercased()
        normalized = normalized.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"(?i)\b(official|audio|video|lyrics|lyric|visualizer|music video|hd|4k)\b"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalArtistKey(_ artist: String?) -> String {
        var normalized = artist?.lowercased() ?? "unknown"
        normalized = normalized.replacingOccurrences(of: #"(?i)\s*-\s*topic$"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"(?i)\bvevo\b"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func displayTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"(?i)\s*\((official audio|official video|official music video|audio|lyrics|lyric video)\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\[(official audio|official video|official music video|audio|lyrics|lyric video)\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayAlbumTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"(?i)^\s*mix\s*-\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\((full album|album|playlist)\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\[(full album|album|playlist)\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeFileName(_ string: String) -> String {
        let cleaned = string
            .replacingOccurrences(of: #"[/\\:?%*|"<>]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Album" : String(cleaned.prefix(80))
    }

    private static func existingThumbnailURL(in directory: URL) -> URL? {
        for ext in ["jpg", "jpeg", "png", "webp", "tif", "tiff"] {
            let existingURL = directory.appendingPathComponent("cover").appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: existingURL.path) {
                return existingURL
            }
        }
        return nil
    }

    private static func thumbnailCandidates(for track: OnlineSearchResult) -> [URL] {
        var candidates: [URL] = []
        if let thumbnailURL = track.thumbnailURL {
            candidates.append(thumbnailURL)
        }

        if track.provider == .youtube, !track.id.isEmpty {
            for name in ["maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"] {
                if let url = URL(string: "https://i.ytimg.com/vi/\(track.id)/\(name).jpg") {
                    candidates.append(url)
                }
            }
        }

        var seen = Set<String>()
        return candidates.filter { url in
            let key = url.absoluteString
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func downloadThumbnailWithYtDlp(executable: String, sourceURL: URL, to directory: URL) async throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await runCommand(
            executable: executable,
            arguments: [
                "--ignore-config",
                "--skip-download",
                "--no-playlist",
                "--write-thumbnail",
                "--retries", "3",
                "--output", directory.appendingPathComponent("cover.%(ext)s").path,
                sourceURL.absoluteString
            ]
        )
        return existingThumbnailURL(in: directory)
    }

    @discardableResult
    private static func downloadThumbnail(_ thumbnailURL: URL?, to directory: URL) async throws -> URL? {
        guard let thumbnailURL else { return nil }
        let (data, response) = try await URLSession.shared.data(from: thumbnailURL)
        if let httpResponse = response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else { return nil }
        }
        if let mimeType = response.mimeType?.lowercased() {
            guard mimeType.hasPrefix("image/") else { return nil }
        }
        guard !data.isEmpty else { return nil }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for ext in ["jpg", "jpeg", "png", "webp", "tif", "tiff"] {
            let existingURL = directory.appendingPathComponent("cover").appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: existingURL.path) {
                try? FileManager.default.removeItem(at: existingURL)
            }
        }
        let savedURL = directory
            .appendingPathComponent("cover")
            .appendingPathExtension(thumbnailExtension(from: response, fallbackURL: thumbnailURL))
        try data.write(to: savedURL, options: .atomic)
        return savedURL
    }

    private static func thumbnailExtension(from response: URLResponse, fallbackURL: URL) -> String {
        if let mimeType = response.mimeType?.lowercased() {
            switch mimeType {
            case "image/jpeg", "image/jpg":
                return "jpg"
            case "image/png":
                return "png"
            case "image/webp":
                return "webp"
            case "image/tiff":
                return "tif"
            default:
                break
            }
        }

        switch fallbackURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "webp", "tif", "tiff":
            return fallbackURL.pathExtension.lowercased()
        default:
            return "jpg"
        }
    }

    private static func audioFileURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard AudioFileType.isSupported(url) else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        .sorted {
            $0.standardizedFileURL.path.localizedStandardCompare($1.standardizedFileURL.path) == .orderedAscending
        }
    }

    fileprivate static func tokenSet(_ string: String) -> Set<String> {
        let normalized = string
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 1 })
    }

    private static func containsAny(_ string: String, terms: [String]) -> Bool {
        let normalized = string.lowercased()
        return terms.contains { normalized.contains($0) }
    }

}

private struct ProcessExecutionResult: Sendable {
    let output: String
    let terminationStatus: Int32
}

private final class ProcessExecutionControl: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case timedOut
    }

    private let process: Process
    private let readHandle: FileHandle
    private let lock = NSLock()
    private var storedStopReason: StopReason?

    init(process: Process, readHandle: FileHandle) {
        self.process = process
        self.readHandle = readHandle
    }

    var stopReason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return storedStopReason
    }

    func stop(reason: StopReason) {
        lock.lock()
        guard storedStopReason == nil, process.isRunning else {
            lock.unlock()
            return
        }
        storedStopReason = reason
        lock.unlock()

        process.terminate()
        try? readHandle.close()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak process] in
            guard let process, process.isRunning else { return }
            #if os(macOS)
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            #else
            process.terminate()
            #endif
        }
    }
}

private struct ProgressEmitter {
    private let aggregatesPlaylistProgress: Bool
    private var lastEmittedProgress: Double?
    private var lastEmissionTime: TimeInterval = 0
    private var playlistIndex = 1
    private var playlistCount = 1

    init(aggregatesPlaylistProgress: Bool) {
        self.aggregatesPlaylistProgress = aggregatesPlaylistProgress
    }

    mutating func consume(_ line: String, to handler: (@Sendable (Double) -> Void)?) {
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if aggregatesPlaylistProgress {
            for index in tokens.indices where index + 3 < tokens.count {
                let marker = tokens[index].lowercased()
                guard marker == "item" || marker == "video",
                      tokens[index + 2].lowercased() == "of",
                      let itemIndex = Int(tokens[index + 1]),
                      let itemCount = Int(tokens[index + 3]),
                      itemIndex > 0,
                      itemCount > 0 else {
                    continue
                }
                playlistIndex = min(itemIndex, itemCount)
                playlistCount = itemCount
                break
            }
        }

        guard let percentToken = tokens.last(where: { $0.contains("%") }),
              let percentRange = percentToken.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let percent = Double(percentToken[percentRange]) else {
            return
        }

        let itemProgress = min(max(percent / 100, 0), 1)
        let progress: Double
        if aggregatesPlaylistProgress, playlistCount > 1 {
            progress = (Double(playlistIndex - 1) + itemProgress) / Double(playlistCount)
        } else {
            progress = itemProgress
        }
        emit(progress, to: handler)
    }

    mutating func emit(
        _ progress: Double,
        to handler: (@Sendable (Double) -> Void)?
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        if let lastEmittedProgress {
            guard lastEmittedProgress < 1,
                  clampedProgress >= lastEmittedProgress else {
                return
            }
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard clampedProgress >= 1 ||
            lastEmittedProgress == nil ||
            (clampedProgress - (lastEmittedProgress ?? 0) >= 0.005 && now - lastEmissionTime >= 0.1) else {
            return
        }

        lastEmittedProgress = clampedProgress
        lastEmissionTime = now
        handler?(clampedProgress)
    }
}

private struct YouTubeMusicClientContext: Sendable {
    let apiKey: String
    let clientVersion: String
    let fetchedAt: Date

    var isFresh: Bool {
        Date().timeIntervalSince(fetchedAt) < 3_600
    }
}

private actor YouTubeMusicClientContextCache {
    private var context: YouTubeMusicClientContext?

    func freshContext() -> YouTubeMusicClientContext? {
        guard let context, context.isFresh else { return nil }
        return context
    }

    func store(_ context: YouTubeMusicClientContext) {
        self.context = context
    }
}

private struct YouTubeSearchCandidate {
    let id: String
    let title: String
    let channel: String?
    let duration: TimeInterval?
    let viewCount: Int?
    let thumbnailURL: URL?
    let isVerifiedArtist: Bool
    let searchPosition: Int
    let sourceBias: Int
    var score: Int = 0

    func scored(queryTokens: Set<String>, wantsRemix: Bool) -> YouTubeSearchCandidate {
        var candidate = self
        let lowerTitle = title.lowercased()
        let lowerChannel = channel?.lowercased() ?? ""
        let titleTokens = YtDlpDownloadService.tokenSet(title)
        let channelTokens = YtDlpDownloadService.tokenSet(lowerChannel)
        let matchingTitleTokens = queryTokens.intersection(titleTokens).count
        let matchingChannelTokens = queryTokens.intersection(channelTokens).count

        var score = sourceBias
        score += max(0, 30 - searchPosition * 2)
        score += matchingTitleTokens * 12
        score += matchingChannelTokens * 8

        if lowerTitle.contains("official audio") { score += 80 }
        if lowerTitle.contains("official lyric") { score += 10 }
        if lowerTitle.contains("audio") { score += 25 }
        if isVerifiedArtist { score += 25 }
        if lowerChannel.contains(" - topic") || lowerChannel.hasSuffix("topic") { score += 65 }
        if lowerChannel.contains("vevo") { score -= 10 }

        if let duration {
            switch duration {
            case 120...360:
                score += 24
            case 60..<120, 361...480:
                score += 8
            default:
                score -= 35
            }
        }

        if let viewCount, viewCount > 0 {
            score += min(Int(log10(Double(viewCount))) * 4, 32)
        }

        if lowerTitle.contains("official video") || lowerTitle.contains("official music video") || lowerTitle.contains("music video") || lowerTitle.contains(" mv") {
            score -= 75
        }

        let hardPenaltyTerms = [
            "reaction", "tutorial", "explained", "review", "hour", "full album",
            "full show", "set", "concert", "karaoke", "instrumental"
        ]
        for term in hardPenaltyTerms where lowerTitle.contains(term) {
            score -= 65
        }

        let variantTerms = ["live", "cover", "lyrics", "lyric", "slowed", "reverb", "nightcore", "sped up"]
        for term in variantTerms where lowerTitle.contains(term) {
            score -= wantsRemix ? 5 : 35
        }

        if lowerTitle.contains("remix") || lowerTitle.contains("edit") {
            score += wantsRemix ? 35 : -15
        }

        candidate.score = score
        return candidate
    }
}

private struct YouTubeAlbumCandidate {
    let id: String
    let title: String
    let artist: String?
    let detailText: String?
    let thumbnailURL: URL?
    let searchPosition: Int
    let sourceBias: Int
    var score: Int = 0

    func scored(queryTokens: Set<String>) -> YouTubeAlbumCandidate {
        var candidate = self
        let lowerTitle = title.lowercased()
        let lowerArtist = artist?.lowercased() ?? ""
        let titleTokens = YtDlpDownloadService.tokenSet(title)
        let artistTokens = YtDlpDownloadService.tokenSet(lowerArtist)

        var score = sourceBias
        score += max(0, 28 - searchPosition * 2)
        score += queryTokens.intersection(titleTokens).count * 14
        score += queryTokens.intersection(artistTokens).count * 8

        if id.hasPrefix("OLAK5") { score += 70 }
        if lowerTitle.contains("album") { score += 24 }
        if lowerTitle.contains("full album") { score += 16 }
        if lowerArtist.contains("topic") { score += 22 }

        let penaltyTerms = ["mix -", "radio", "reaction", "review", "live", "concert", "karaoke", "instrumental"]
        for term in penaltyTerms where lowerTitle.contains(term) {
            score -= 55
        }

        candidate.score = score
        return candidate
    }
}

enum YtDlpError: LocalizedError {
    case notFound
    case downloadFailed(String)
    case commandFailed(String)
    case commandTimedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Nightwing could not find its download helper."
        case let .downloadFailed(message):
            return "Download failed: \(message)"
        case let .commandFailed(command):
            return "Command failed: \(command)"
        case .commandTimedOut:
            return "The download helper timed out."
        case let .launchFailed(reason):
            return "Could not start the download helper: \(reason)"
        }
    }
}
