import Foundation
#if canImport(os)
import os
#endif

actor YtDlpDownloadService {
    private static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let maxSearchCacheEntries = 24
    private static let downloadRetryDelaysNanoseconds: [UInt64] = [0, 700_000_000, 1_800_000_000]
    private static let youTubeMusicClientContextCache = YouTubeMusicClientContextCache()
    private let store = OnlineTrackStore()
    #if canImport(os)
    private let logger = Logger(subsystem: "com.nightwing", category: "YtDlp")
    #endif
    private let maxConcurrentDownloads = 2
    private var activeDownloads = 0
    private var inFlightTrackDownloads: [String: Task<URL, Error>] = [:]
    private var inFlightAlbumDownloads: [String: Task<URL, Error>] = [:]
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

        let musicCandidates = try await Self.fetchYouTubeMusicCandidates(query: trimmedQuery)
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

        let musicAlbums = try await Self.fetchYouTubeMusicAlbumCandidates(query: trimmedQuery)
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
        guard let ytDlpPath = Self.locateYtDlp() else {
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
            do {
                return try await Self.downloadWithProgress(
                    executable: ytDlpPath,
                    arguments: Self.directAudioDownloadArguments(
                        format: Self.preferredAudioFormat(for: track),
                        outputTemplate: outputTemplate,
                        sourceURL: track.sourceURL
                    ),
                    expectedFileURL: downloadsDir.appendingPathComponent("\(sourceHash).\(extensionName)"),
                    progressHandler: progressHandler
                )
            } catch {
                return try await Self.downloadWithProgress(
                    executable: ytDlpPath,
                    arguments: Self.extractedAudioDownloadArguments(
                        extensionName: extensionName,
                        outputTemplate: outputTemplate,
                        sourceURL: track.sourceURL
                    ),
                    expectedFileURL: downloadsDir.appendingPathComponent("\(sourceHash).\(extensionName)"),
                    progressHandler: progressHandler
                )
            }
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
        guard let ytDlpPath = Self.locateYtDlp() else {
            throw YtDlpError.notFound
        }

        let sourceHash = OnlineTrackStore.hashKey(for: album.sourceURL)
        let albumDir = Self.onlineAlbumDirectory(sourceHash: sourceHash, title: album.title)
        if let existingAlbumDir = Self.existingUsableAlbumDirectory(at: albumDir) {
            progressHandler?(1)
            return existingAlbumDir
        }

        if let inFlightDownload = inFlightAlbumDownloads[sourceHash] {
            let folderURL = try await inFlightDownload.value
            progressHandler?(1)
            return folderURL
        }

        while activeDownloads >= maxConcurrentDownloads {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        activeDownloads += 1
        defer {
            activeDownloads -= 1
            inFlightAlbumDownloads[sourceHash] = nil
        }

        let downloadTask = Task {
            try await Self.downloadAlbumWithRetries(
                executable: ytDlpPath,
                album: album,
                sourceHash: sourceHash,
                finalDirectory: albumDir,
                progressHandler: progressHandler
            )
        }
        inFlightAlbumDownloads[sourceHash] = downloadTask

        let folderURL = try await downloadTask.value
        progressHandler?(1)
        return folderURL
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
        if let bundleURL = Bundle.main.url(forResource: "yt-dlp", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundleURL.path) {
            return bundleURL.path
        }

        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp"),
           FileManager.default.isExecutableFile(atPath: bundleURL.path) {
            return bundleURL.path
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.components(separatedBy: ":") {
                let candidate = (dir as NSString).appendingPathComponent("yt-dlp")
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return nil
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
            "--newline",
            "--no-playlist",
            "--no-mtime",
            "--concurrent-fragments", "4",
            "--format", format,
            "--output", outputTemplate,
            sourceURL.absoluteString
        ]
    }

    private static func extractedAudioDownloadArguments(extensionName: String, outputTemplate: String, sourceURL: URL) -> [String] {
        [
            "--newline",
            "--no-playlist",
            "--no-mtime",
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

    private static func downloadAlbumWithRetries(
        executable: String,
        album: OnlineAlbumSearchResult,
        sourceHash: String,
        finalDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var lastError: Error?

        for (attempt, delay) in downloadRetryDelaysNanoseconds.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }

            let stagingDirectory = temporaryAlbumDirectory(sourceHash: sourceHash)
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
                lastError = error
                try? FileManager.default.removeItem(at: stagingDirectory)

                #if canImport(os)
                Logger(subsystem: "com.nightwing", category: "YtDlp").error("Album download attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                #endif
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var progressEmitter = ProgressEmitter()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        var output = ""
        while process.isRunning {
            let data = pipe.fileHandleForReading.availableData
            guard !data.isEmpty else {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            output.append(text)
            if let progress = Self.progressPercent(from: text) {
                progressEmitter.emit(progress, to: progressHandler)
            }
        }

        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingData.isEmpty {
            let text = String(decoding: remainingData, as: UTF8.self)
            output.append(text)
            if let progress = Self.progressPercent(from: text) {
                progressEmitter.emit(progress, to: progressHandler, force: true)
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = output
                .split(separator: "\n")
                .last
                .map(String.init) ?? "Unknown error"
            throw YtDlpError.downloadFailed(message)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var progressEmitter = ProgressEmitter()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        var output = ""
        while process.isRunning {
            let data = pipe.fileHandleForReading.availableData
            guard !data.isEmpty else {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            output.append(text)
            if let progress = Self.progressPercent(from: text) {
                progressEmitter.emit(progress, to: progressHandler)
            }
        }

        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingData.isEmpty {
            let text = String(decoding: remainingData, as: UTF8.self)
            output.append(text)
            if let progress = Self.progressPercent(from: text) {
                progressEmitter.emit(progress, to: progressHandler, force: true)
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = output
                .split(separator: "\n")
                .last
                .map(String.init) ?? "Unknown error"
            throw YtDlpError.downloadFailed(message)
        }
    }

    private static func runCommand(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw YtDlpError.commandFailed(output.isEmpty ? executable : output)
        }

        return output
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

    private static func progressPercent(from text: String) -> Double? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)%"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let token = text[range].replacingOccurrences(of: "%", with: "")
        guard let percent = Double(token.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return min(max(percent / 100, 0), 1)
    }
}

private struct ProgressEmitter {
    private var lastEmittedProgress: Double?

    mutating func emit(
        _ progress: Double,
        to handler: (@Sendable (Double) -> Void)?,
        force: Bool = false
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        guard force ||
            clampedProgress >= 1 ||
            lastEmittedProgress == nil ||
            abs(clampedProgress - (lastEmittedProgress ?? 0)) >= 0.01 else {
            return
        }

        lastEmittedProgress = clampedProgress
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

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "yt-dlp is not bundled or installed."
        case let .downloadFailed(message):
            return "Download failed: \(message)"
        case let .commandFailed(command):
            return "Command failed: \(command)"
        }
    }
}
