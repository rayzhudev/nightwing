import AVFoundation
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import MediaPlayer
#endif
#if canImport(AppKit)
import AppKit
private typealias NightwingPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias NightwingPlatformImage = UIImage
#endif

private struct PlaybackResumeSnapshot: Equatable {
    var queue: PlaybackQueue
    var resumeState: PlaybackResumeState?
}

@MainActor
final class NightwingAppModel: ObservableObject {
    private static let playbackAnalysisThrottleNanoseconds: UInt64 = 120_000_000
    private static let playbackAnalysisSaveBatchSize = 12
    private static let playbackResumeSaveInterval: TimeInterval = 5

    @Published private(set) var library: LocalLibrary = .empty {
        didSet {
            if library.tracks != oldValue.tracks {
                needsLibraryCacheRebuild = true
            }
        }
    }
    @Published var statusMessage: String?
    @Published var isImporting = false
    @Published private(set) var optimisticPlaybackTrackID: Track.ID?
    #if os(macOS)
    @Published private(set) var onlineSearchResults: [OnlineSearchResult] = []
    @Published private(set) var onlineAlbumResults: [OnlineAlbumSearchResult] = []
    @Published private(set) var isSearchingOnline = false
    #endif

    let player = PlayerEngine(profile: .nightcore)

    private let importService = LibraryImportService()
    #if os(macOS)
    private let onlineSearchService = YtDlpDownloadService()
    private var onlineSearchTask: Task<Void, Never>?
    private var pendingOnlineTrackActions: [OnlineSearchResult.ID: [(Track) -> Void]] = [:]
    private var onlineTrackDownloadTasks: [OnlineSearchResult.ID: Task<Void, Never>] = [:]
    private var onlineAlbumDownloadTasks: [OnlineAlbumSearchResult.ID: Task<Void, Never>] = [:]
    private var onlineTrackDownloadStates: [OnlineSearchResult.ID: OnlineSearchResult.DownloadState] = [:]
    private var onlineAlbumDownloadStates: [OnlineAlbumSearchResult.ID: OnlineSearchResult.DownloadState] = [:]
    #endif
    private let store: JSONLocalLibraryStore?
    private var folderRefreshTimer: Timer?
    private var playbackAnalysisTask: Task<Void, Never>?
    private var playbackRequestID = UUID()
    private var playbackStateCancellable: AnyCancellable?
    private var playbackResumeSaveTask: Task<Void, Never>?
    private var lastPlaybackResumeSaveDate = Date.distantPast
    private var lastSavedPlaybackResumeSnapshot: PlaybackResumeSnapshot?
    private var isRestoringPlayback = false
    private var tracksByID: [Track.ID: Track] = [:]
    private var tracksByStandardizedPath: [String: Track] = [:]
    private var sortedTracksCache: [Track] = []
    private var albumGroupsCache: [LibraryAlbumGroup] = []
    private var recentlyAddedTracksCache: [Track] = []
    private var onlineDownloadedTracksCache: [Track] = []
    private var needsLibraryCacheRebuild = true
    #if os(iOS)
    private var musicLibraryChangeObserver: NSObjectProtocol?
    private var isSyncingSystemMusicLibrary = false
    #endif

    init() {
        store = try? JSONLocalLibraryStore.defaultStore()
        observePlaybackState()
        Task {
            await loadLibrary()
            #if os(iOS)
            await importSystemMusicLibraryIfPossible(requestAuthorization: true, showStatus: true)
            #endif
            refreshOpenedFolders()
        }
        startFolderRefreshTimer()
    }

    deinit {
        folderRefreshTimer?.invalidate()
        playbackAnalysisTask?.cancel()
        playbackStateCancellable?.cancel()
        playbackResumeSaveTask?.cancel()
        #if os(macOS)
        onlineSearchTask?.cancel()
        #endif
        #if os(iOS)
        if let musicLibraryChangeObserver {
            NotificationCenter.default.removeObserver(musicLibraryChangeObserver)
        }
        MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        #endif
    }

    var sortedTracks: [Track] {
        rebuildLibraryCacheIfNeeded()
        return sortedTracksCache
    }

    var isPlaybackStarting: Bool {
        optimisticPlaybackTrackID != nil
    }

    var albumGroups: [LibraryAlbumGroup] {
        rebuildLibraryCacheIfNeeded()
        return albumGroupsCache
    }

    var recentlyAddedTracks: [Track] {
        rebuildLibraryCacheIfNeeded()
        return recentlyAddedTracksCache
    }

    var onlineDownloadedTracks: [Track] {
        rebuildLibraryCacheIfNeeded()
        return onlineDownloadedTracksCache
    }

    func isOnlineDownloadedTrack(_ track: Track) -> Bool {
        Self.isOnlineDownloadedTrack(track)
    }

    func isOnlineAlbumDownloadTrack(_ track: Track) -> Bool {
        Self.isOnlineAlbumDownloadTrack(track)
    }

    func hasDownloadedArtwork(for track: Track) -> Bool {
        guard isOnlineDownloadedTrack(track) else { return false }
        if let artworkURL = track.artworkURL, FileManager.default.fileExists(atPath: artworkURL.path) {
            return true
        }

        let folderURL = track.fileURL.deletingLastPathComponent()
        return ["cover", "folder", "front", "album", "artwork"].contains { name in
            ["jpg", "jpeg", "png", "webp", "tif", "tiff"].contains { ext in
                FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(name).appendingPathExtension(ext).path)
            }
        }
    }

    func filteredTracks(matching query: String) -> [Track] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return sortedTracks }
        let loweredQuery = trimmedQuery.lowercased()

        return sortedTracks.filter { track in
            [
                track.title,
                track.artist,
                track.album,
                track.albumArtist,
                track.genre,
                track.fileURL.lastPathComponent
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(loweredQuery) }
        }
    }

    func filteredAlbumGroups(matching query: String) -> [LibraryAlbumGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return albumGroups }
        let loweredQuery = trimmedQuery.lowercased()

        return albumGroups.filter { album in
            let searchableValues = [
                album.title,
                album.artistSummary
            ] + album.tracks.flatMap { track in
                [
                    track.title,
                    track.artist,
                    track.albumArtist,
                    track.genre,
                    track.fileURL.lastPathComponent
                ].compactMap { $0 }
            }

            return searchableValues
                .map { $0.lowercased() }
                .contains { $0.contains(loweredQuery) }
        }
    }

    #if os(macOS)
    func searchOnline(query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        onlineSearchTask?.cancel()

        guard !trimmedQuery.isEmpty else {
            onlineSearchResults = []
            onlineAlbumResults = []
            isSearchingOnline = false
            return
        }

        onlineSearchTask = Task { @MainActor [weak self] in
            self?.isSearchingOnline = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }

            do {
                async let trackResults = onlineSearchService.search(query: trimmedQuery)
                async let albumResults = onlineSearchService.searchAlbums(query: trimmedQuery)
                let results = try await trackResults
                let albums = try await albumResults
                guard !Task.isCancelled else { return }
                onlineSearchResults = await resultsWithCacheState(results)
                onlineAlbumResults = await albumsWithDownloadState(albums)
            } catch {
                guard !Task.isCancelled else { return }
                onlineSearchResults = []
                onlineAlbumResults = []
                statusMessage = "Online search failed: \(error.localizedDescription)"
            }

            isSearchingOnline = false
        }
    }

    func clearOnlineSearchResults() {
        onlineSearchTask?.cancel()
        onlineSearchResults = []
        onlineAlbumResults = []
        isSearchingOnline = false
    }

    func getCachedTrack(hash: String) async -> CachedTrackEntry? {
        try? await onlineSearchService.getCachedEntry(sourceHash: hash)
    }

    func downloadOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result, autoplay: false)
    }

    func deleteOnlineTrack(_ result: OnlineSearchResult) {
        let sourceHash = OnlineTrackStore.hashKey(for: result.sourceURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let cached = try? await onlineSearchService.getCachedEntry(sourceHash: sourceHash) else {
                setOnlineDownloadState(for: result.id, state: .idle)
                return
            }
            await deleteOnlineDownloadedFile(URL(fileURLWithPath: cached.localFileURL))
            setOnlineDownloadState(for: result.id, state: .idle)
        }
    }

    func deleteOnlineDownloadedTrack(_ track: Track) {
        guard isOnlineDownloadedTrack(track) else { return }
        Task { @MainActor [weak self] in
            await self?.deleteOnlineDownloadedFile(track.fileURL)
        }
    }

    func deleteOnlineDownloadedAlbum(_ album: LibraryAlbumGroup) {
        let albumTracks = album.tracks.filter(Self.isOnlineAlbumDownloadTrack)
        guard let firstTrack = albumTracks.first else { return }
        let albumFolderURL = firstTrack.fileURL.deletingLastPathComponent()

        Task { @MainActor [weak self] in
            await self?.deleteOnlineDownloadedAlbumFolder(albumFolderURL, tracks: albumTracks)
        }
    }

    func downloadOnlineAlbum(_ album: OnlineAlbumSearchResult) {
        let albumID = album.id

        if case let .completed(folderURL) = onlineAlbumDownloadState(for: album) {
            Task { @MainActor [weak self] in
                await self?.importDownloadedOnlineAlbum(folderURL, fallback: album)
            }
            return
        }

        if onlineAlbumDownloadTasks[albumID] != nil {
            setOnlineAlbumDownloadState(for: albumID, state: onlineAlbumDownloadStates[albumID] ?? .downloading(progress: 0))
            return
        }

        setOnlineAlbumDownloadState(for: albumID, state: .downloading(progress: 0))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.onlineAlbumDownloadTasks[albumID] = nil
            }

            do {
                let albumFolderURL = try await onlineSearchService.downloadAlbum(album) { progress in
                    Task { @MainActor [weak self] in
                        self?.setOnlineAlbumDownloadState(for: albumID, state: .downloading(progress: progress))
                    }
                }

                setOnlineAlbumDownloadState(for: albumID, state: .completed(fileURL: albumFolderURL))
                await importDownloadedOnlineAlbum(albumFolderURL, fallback: album)
            } catch {
                setOnlineAlbumDownloadState(for: albumID, state: .failed(error.localizedDescription))
                statusMessage = "Album download failed: \(error.localizedDescription)"
            }
        }
        onlineAlbumDownloadTasks[albumID] = task
    }

    func playOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result, autoplay: true)
    }

    func playNextOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result, autoplay: false) { [weak self] track in
            self?.playNext(track)
        }
    }

    func enqueueOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result, autoplay: false) { [weak self] track in
            self?.enqueue(track)
        }
    }

    private func prepareOnlineTrack(_ result: OnlineSearchResult, autoplay: Bool, completion: ((Track) -> Void)? = nil) {
        let sourceID = result.id
        let action: ((Track) -> Void)? = (autoplay || completion != nil) ? { [weak self] track in
            if autoplay {
                self?.play(track, within: [track])
            }
            completion?(track)
        } : nil

        if case let .completed(fileURL) = onlineTrackDownloadState(for: result) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let track = await importDownloadedOnlineTrack(fileURL, fallback: result) {
                    action?(track)
                }
            }
            return
        }

        if onlineTrackDownloadTasks[sourceID] != nil || onlineTrackDownloadState(for: result).isDownloading {
            if let action {
                appendPendingOnlineTrackAction(action, for: sourceID)
            }
            setOnlineDownloadState(for: sourceID, state: onlineTrackDownloadStates[sourceID] ?? .downloading(progress: 0))
            return
        }

        if let action {
            appendPendingOnlineTrackAction(action, for: sourceID)
        }

        setOnlineDownloadState(for: sourceID, state: .downloading(progress: 0))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.onlineTrackDownloadTasks[sourceID] = nil
            }

            do {
                let fileURL = try await onlineSearchService.download(result) { progress in
                    Task { @MainActor [weak self] in
                        self?.setOnlineDownloadState(for: sourceID, state: .downloading(progress: progress))
                    }
                }

                setOnlineDownloadState(for: sourceID, state: .completed(fileURL: fileURL))
                if let track = await importDownloadedOnlineTrack(fileURL, fallback: result) {
                    runPendingOnlineTrackActions(for: sourceID, track: track)
                }
            } catch {
                pendingOnlineTrackActions[sourceID] = nil
                setOnlineDownloadState(for: sourceID, state: .failed(error.localizedDescription))
                statusMessage = "Download failed: \(error.localizedDescription)"
            }
        }
        onlineTrackDownloadTasks[sourceID] = task
    }

    private func runPendingOnlineTrackActions(for id: OnlineSearchResult.ID, track: Track) {
        let actions = pendingOnlineTrackActions.removeValue(forKey: id) ?? []
        for action in actions {
            action(track)
        }
    }

    private func appendPendingOnlineTrackAction(_ action: @escaping (Track) -> Void, for id: OnlineSearchResult.ID) {
        pendingOnlineTrackActions[id, default: []].append(action)
    }

    private func onlineTrackDownloadState(for result: OnlineSearchResult) -> OnlineSearchResult.DownloadState {
        if let state = onlineTrackDownloadStates[result.id] {
            return state
        }
        if let visibleResult = onlineSearchResults.first(where: { $0.id == result.id }) {
            return visibleResult.downloadState
        }
        return result.downloadState
    }

    private func onlineAlbumDownloadState(for album: OnlineAlbumSearchResult) -> OnlineSearchResult.DownloadState {
        if let state = onlineAlbumDownloadStates[album.id] {
            return state
        }
        if let visibleAlbum = onlineAlbumResults.first(where: { $0.id == album.id }) {
            return visibleAlbum.downloadState
        }
        return album.downloadState
    }

    private func setOnlineDownloadState(for id: OnlineSearchResult.ID, state: OnlineSearchResult.DownloadState) {
        if state.isIdle {
            onlineTrackDownloadStates[id] = nil
        } else {
            onlineTrackDownloadStates[id] = state
        }

        guard let index = onlineSearchResults.firstIndex(where: { $0.id == id }) else { return }
        onlineSearchResults[index].downloadState = state
    }

    private func setOnlineAlbumDownloadState(for id: OnlineAlbumSearchResult.ID, state: OnlineSearchResult.DownloadState) {
        if state.isIdle {
            onlineAlbumDownloadStates[id] = nil
        } else {
            onlineAlbumDownloadStates[id] = state
        }

        guard let index = onlineAlbumResults.firstIndex(where: { $0.id == id }) else { return }
        onlineAlbumResults[index].downloadState = state
    }

    private func deleteOnlineDownloadedFile(_ fileURL: URL) async {
        let standardizedURL = fileURL.standardizedFileURL
        let tracksToRemove = library.tracks.filter {
            $0.fileURL.standardizedFileURL.path == standardizedURL.path
        }

        do {
            _ = try await onlineSearchService.removeCachedEntry(localFileURL: standardizedURL)
        } catch {
            statusMessage = "Could not update online cache: \(error.localizedDescription)"
        }

        for track in tracksToRemove {
            library.deleteTrack(id: track.id)
        }

        let path = standardizedURL.path
        let onlineTracksMarker = "/Nightwing/Online Downloads/Tracks/"
        let deleteURL: URL
        if path.contains(onlineTracksMarker) {
            deleteURL = standardizedURL.deletingLastPathComponent()
        } else {
            deleteURL = standardizedURL
        }

        do {
            if FileManager.default.fileExists(atPath: deleteURL.path) {
                try FileManager.default.removeItem(at: deleteURL)
            }
            clearCompletedDownloadStates(matchingDeletedURL: deleteURL, originalURL: standardizedURL)
            for resultIndex in onlineSearchResults.indices {
                if completedDownloadState(onlineSearchResults[resultIndex].downloadState, matchesDeletedURL: deleteURL, originalURL: standardizedURL) {
                    onlineSearchResults[resultIndex].downloadState = .idle
                }
            }
            for albumIndex in onlineAlbumResults.indices {
                if completedDownloadState(onlineAlbumResults[albumIndex].downloadState, matchesDeletedURL: deleteURL, originalURL: standardizedURL) {
                    onlineAlbumResults[albumIndex].downloadState = .idle
                }
            }
            Task {
                await persistLibrary()
            }
            statusMessage = "Deleted online download."
        } catch {
            statusMessage = "Could not delete online download: \(error.localizedDescription)"
        }
    }

    private func deleteOnlineDownloadedAlbumFolder(_ folderURL: URL, tracks: [Track]) async {
        let standardizedURL = folderURL.standardizedFileURL

        for track in tracks {
            library.deleteTrack(id: track.id)
        }

        do {
            if FileManager.default.fileExists(atPath: standardizedURL.path) {
                try FileManager.default.removeItem(at: standardizedURL)
            }
            clearCompletedDownloadStates(matchingDeletedURL: standardizedURL, originalURL: standardizedURL)
            for albumIndex in onlineAlbumResults.indices {
                if completedDownloadState(onlineAlbumResults[albumIndex].downloadState, matchesDeletedURL: standardizedURL, originalURL: standardizedURL) {
                    onlineAlbumResults[albumIndex].downloadState = .idle
                }
            }
            Task {
                await persistLibrary()
            }
            statusMessage = "Deleted online album download."
        } catch {
            statusMessage = "Could not delete online album download: \(error.localizedDescription)"
        }
    }

    private func clearCompletedDownloadStates(matchingDeletedURL deletedURL: URL, originalURL: URL) {
        let trackIDsToClear = onlineTrackDownloadStates.compactMap { id, state in
            completedDownloadState(state, matchesDeletedURL: deletedURL, originalURL: originalURL) ? id : nil
        }
        for id in trackIDsToClear {
            onlineTrackDownloadStates[id] = nil
        }

        let albumIDsToClear = onlineAlbumDownloadStates.compactMap { id, state in
            completedDownloadState(state, matchesDeletedURL: deletedURL, originalURL: originalURL) ? id : nil
        }
        for id in albumIDsToClear {
            onlineAlbumDownloadStates[id] = nil
        }
    }

    private func completedDownloadState(_ state: OnlineSearchResult.DownloadState, matchesDeletedURL deletedURL: URL, originalURL: URL) -> Bool {
        guard let completedURL = state.completedFileURL else { return false }

        let completedPath = completedURL.standardizedFileURL.path
        let deletedPath = deletedURL.standardizedFileURL.path
        let originalPath = originalURL.standardizedFileURL.path

        return completedPath == originalPath
            || completedPath == deletedPath
            || completedPath.hasPrefix(deletedPath + "/")
            || originalPath.hasPrefix(completedPath + "/")
    }

    private func resultsWithCacheState(_ results: [OnlineSearchResult]) async -> [OnlineSearchResult] {
        var updatedResults = results
        let cachedEntries = (try? await onlineSearchService.getAllCachedEntries()) ?? []
        var entriesByHash: [String: CachedTrackEntry] = [:]
        for entry in cachedEntries {
            entriesByHash[entry.sourceHash] = entry
        }

        for index in updatedResults.indices {
            if let state = onlineTrackDownloadStates[updatedResults[index].id] {
                updatedResults[index].downloadState = state
                continue
            }

            let hash = OnlineTrackStore.hashKey(for: updatedResults[index].sourceURL)
            guard let cached = entriesByHash[hash] else { continue }
            let fileURL = URL(fileURLWithPath: cached.localFileURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            updatedResults[index].downloadState = .completed(fileURL: fileURL)
        }
        return updatedResults
    }

    private func albumsWithDownloadState(_ albums: [OnlineAlbumSearchResult]) async -> [OnlineAlbumSearchResult] {
        var updatedAlbums = albums

        for index in updatedAlbums.indices {
            if let state = onlineAlbumDownloadStates[updatedAlbums[index].id] {
                updatedAlbums[index].downloadState = state
                continue
            }

            if let existingDirectory = await onlineSearchService.existingAlbumDirectory(for: updatedAlbums[index]) {
                updatedAlbums[index].downloadState = .completed(fileURL: existingDirectory)
            }
        }

        return updatedAlbums
    }

    private func importDownloadedOnlineTrack(_ fileURL: URL, fallback result: OnlineSearchResult) async -> Track? {
        if let existingTrack = library.tracks.first(where: { $0.fileURL.standardizedFileURL.path == fileURL.standardizedFileURL.path }) {
            scheduleOnlineArtworkFinalization(for: existingTrack.id, source: result)
            return existingTrack
        }

        guard let track = onlineTrack(from: fileURL, fallback: result) else {
            statusMessage = "Downloaded but could not import: unsupported file type."
            return nil
        }

        library.upsertTracks([track])
        scheduleOnlineArtworkFinalization(for: track.id, source: result)
        schedulePostImportLibraryMaintenance(analyze: false)
        statusMessage = "Downloaded \(track.title)."
        return track
    }

    private func scheduleOnlineArtworkFinalization(for trackID: Track.ID, source result: OnlineSearchResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if await self.applyOnlineArtworkIfAvailable(for: trackID, source: result) {
                return
            }

            let retryDelays: [UInt64] = [500_000_000, 1_500_000_000, 3_000_000_000]
            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                if await self.applyOnlineArtworkIfAvailable(for: trackID, source: result) {
                    return
                }
            }
        }
    }

    private func applyOnlineArtworkIfAvailable(for trackID: Track.ID, source result: OnlineSearchResult) async -> Bool {
        guard let artworkURL = try? await onlineSearchService.ensureThumbnail(for: result) else {
            return false
        }

        guard let index = library.tracks.firstIndex(where: { $0.id == trackID }) else {
            return true
        }

        let standardizedArtworkPath = artworkURL.standardizedFileURL.path
        if library.tracks[index].artworkURL?.standardizedFileURL.path == standardizedArtworkPath {
            return true
        }

        var updatedTrack = library.tracks[index]
        updatedTrack.artworkURL = artworkURL
        updatedTrack.artworkBookmarkData = try? artworkURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        updatedTrack.artworkCacheKey = "\(OnlineTrackStore.hashKey(for: result.sourceURL))-online-artwork"

        var updatedLibrary = library
        updatedLibrary.tracks[index] = updatedTrack
        library = updatedLibrary
        await persistLibrary()
        return true
    }

    private func onlineTrack(from fileURL: URL, fallback result: OnlineSearchResult) -> Track? {
        guard let fileType = AudioFileType(fileExtension: fileURL.pathExtension) else {
            return nil
        }

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = onlineSidecarArtworkURL(for: fileURL)
        let artworkBookmarkData = artworkURL.flatMap {
            try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let artworkCacheKey = artworkURL == nil ? nil : "\(OnlineTrackStore.hashKey(for: result.sourceURL))-online-artwork"

        return Track(
            fileURL: fileURL,
            bookmarkData: try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            title: title.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : title,
            artist: result.artist,
            album: "Online Downloads",
            duration: result.duration,
            artworkCacheKey: artworkCacheKey,
            artworkURL: artworkURL,
            artworkBookmarkData: artworkBookmarkData,
            fileType: fileType,
            playbackNormalizationGain: 1.0,
            playbackEndTime: nil,
            playbackAnalysisVersion: PlaybackAnalysis.currentVersion,
            availability: FileManager.default.fileExists(atPath: fileURL.path) ? .available : .missing
        )
    }

    private func onlineSidecarArtworkURL(for fileURL: URL) -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        for fileExtension in ["jpg", "jpeg", "png", "webp", "tif", "tiff"] {
            let candidate = directory.appendingPathComponent("cover").appendingPathExtension(fileExtension)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func importDownloadedOnlineAlbum(_ folderURL: URL, fallback album: OnlineAlbumSearchResult) async {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: folderURL,
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

            let importResult = await importService.importFiles(at: fileURLs, albumOverride: album.title)
            var importedTracks = importResult.tracks
            for index in importedTracks.indices where importedTracks[index].artist == nil {
                importedTracks[index].artist = album.artist
            }

            library.upsertTracks(importedTracks)
            schedulePostImportLibraryMaintenance()

            if importResult.failures.isEmpty {
                statusMessage = "Downloaded \(album.title)."
            } else {
                statusMessage = "Downloaded \(importedTracks.count) track\(importedTracks.count == 1 ? "" : "s"); \(importResult.failures.count) failed."
            }
        } catch {
            statusMessage = "Downloaded but could not import album: \(error.localizedDescription)"
        }
    }

    private func schedulePostImportLibraryMaintenance(analyze: Bool = true) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistLibrary()
            if analyze {
                self.startPlaybackAnalysis()
            }
        }
    }
    #endif

    #if os(iOS)
    func importSystemMusicLibrary() {
        Task {
            await importSystemMusicLibraryIfPossible(requestAuthorization: true, showStatus: true)
        }
    }

    private func importSystemMusicLibraryIfPossible(requestAuthorization: Bool, showStatus: Bool) async {
        guard !isSyncingSystemMusicLibrary else { return }

        let status = await systemMusicLibraryAuthorizationStatus(requestAuthorization: requestAuthorization)
        guard status == .authorized else {
            if showStatus {
                switch status {
                case .denied, .restricted:
                    statusMessage = "Music Library access is off. Enable it in Settings to import iPhone songs."
                case .notDetermined:
                    statusMessage = "Music Library access was not granted."
                default:
                    statusMessage = "Could not access the iPhone Music library."
                }
            }
            return
        }

        startWatchingSystemMusicLibrary()
        isSyncingSystemMusicLibrary = true
        isImporting = true
        defer {
            isSyncingSystemMusicLibrary = false
            isImporting = false
        }

        let items = MPMediaQuery.songs().items ?? []
        let tracks = items.compactMap(systemMusicTrack)
        guard !tracks.isEmpty else {
            if showStatus {
                statusMessage = "No locally playable iPhone Music songs were found."
            }
            return
        }

        let previousCount = library.tracks.count
        library.upsertTracks(tracks)
        let importedCount = max(library.tracks.count - previousCount, 0)
        await persistLibrary()
        startPlaybackAnalysis()

        if showStatus {
            if importedCount > 0 {
                statusMessage = "Imported \(importedCount) iPhone Music track\(importedCount == 1 ? "" : "s")."
            } else {
                statusMessage = "iPhone Music library is up to date."
            }
        }
    }

    private func systemMusicLibraryAuthorizationStatus(requestAuthorization: Bool) async -> MPMediaLibraryAuthorizationStatus {
        let currentStatus = MPMediaLibrary.authorizationStatus()
        guard currentStatus == .notDetermined, requestAuthorization else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func startWatchingSystemMusicLibrary() {
        guard musicLibraryChangeObserver == nil else { return }

        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        musicLibraryChangeObserver = NotificationCenter.default.addObserver(
            forName: .MPMediaLibraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.importSystemMusicLibraryIfPossible(requestAuthorization: false, showStatus: false)
            }
        }
    }

    private func systemMusicTrack(from item: MPMediaItem) -> Track? {
        guard let assetURL = item.assetURL else { return nil }

        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = item.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumArtist = item.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let genre = item.genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileType = AudioFileType(fileExtension: assetURL.pathExtension) ?? .m4a

        return Track(
            fileURL: assetURL,
            title: title?.isEmpty == false ? title! : "Untitled Song",
            artist: artist?.isEmpty == false ? artist : nil,
            album: album?.isEmpty == false ? album : "iPhone Music",
            albumArtist: albumArtist?.isEmpty == false ? albumArtist : nil,
            genre: genre?.isEmpty == false ? genre : nil,
            trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
            discNumber: item.discNumber > 0 ? item.discNumber : nil,
            duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
            artworkCacheKey: item.artwork == nil ? nil : "media-library-\(item.persistentID)-artwork",
            fileType: fileType,
            dateAdded: item.dateAdded,
            availability: .available
        )
    }
    #endif

    func albumGroup(id: LibraryAlbumGroup.ID) -> LibraryAlbumGroup? {
        albumGroups.first { $0.id == id }
    }

    func playlist(id: Playlist.ID) -> Playlist? {
        library.playlists.first { $0.id == id }
    }

    func tracks(for playlist: Playlist) -> [Track] {
        playlistTrackEntries(for: playlist).map(\.track)
    }

    func playlistTrackEntries(for playlist: Playlist) -> [PlaylistTrackEntry] {
        rebuildLibraryCacheIfNeeded()
        return playlist.items.compactMap { item -> PlaylistTrackEntry? in
            guard let track = tracksByID[item.trackID] else { return nil }
            return PlaylistTrackEntry(item: item, track: track)
        }
    }

    func track(for item: PlaybackQueueItem?) -> Track? {
        guard let item else { return nil }
        rebuildLibraryCacheIfNeeded()

        if let trackID = item.trackID,
           let track = tracksByID[trackID] {
            return track
        }

        return tracksByStandardizedPath[item.url.standardizedFileURL.path]
    }

    func track(id: Track.ID) -> Track? {
        rebuildLibraryCacheIfNeeded()
        return tracksByID[id]
    }

    func currentDisplayTrack() -> Track? {
        if let optimisticPlaybackTrackID,
           let track = track(id: optimisticPlaybackTrackID) {
            return track
        }

        return track(for: player.state.currentItem)
    }

    func isCurrentTrack(_ track: Track) -> Bool {
        if optimisticPlaybackTrackID == track.id {
            return true
        }

        return self.track(for: player.state.currentItem)?.id == track.id
    }

    func loadLibrary() async {
        guard let store else {
            statusMessage = "Could not create a local library store."
            return
        }

        do {
            var loadedLibrary = try await store.load()
            loadedLibrary.markMissingTracks()
            library = loadedLibrary
            lastSavedPlaybackResumeSnapshot = PlaybackResumeSnapshot(
                queue: loadedLibrary.queue,
                resumeState: loadedLibrary.playbackResumeState
            )
            restorePlaybackIfNeeded(from: loadedLibrary)
            startPlaybackAnalysis()
        } catch {
            statusMessage = "Could not load library: \(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task {
            isImporting = true
            defer { isImporting = false }

            let result = await importService.importFiles(at: urls)
            library.upsertTracks(result.tracks)
            await persistLibrary()
            startPlaybackAnalysis()

            if result.failures.isEmpty {
                statusMessage = "Imported \(result.tracks.count) track\(result.tracks.count == 1 ? "" : "s")."
            } else {
                statusMessage = "Imported \(result.tracks.count) track\(result.tracks.count == 1 ? "" : "s"); \(result.failures.count) failed."
            }
        }
    }

    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task {
            isImporting = true
            defer { isImporting = false }

            var fileURLs: [URL] = []
            var importedTrackCount = 0
            var failureCount = 0
            var importedFolderCount = 0

            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    do {
                        let (folderSource, result) = try await importService.importFolder(at: url)
                        library.upsertFolderSource(folderSource)
                        library.upsertTracks(result.tracks)
                        importedTrackCount += result.tracks.count
                        failureCount += result.failures.count
                        importedFolderCount += 1
                    } catch {
                        failureCount += 1
                    }
                } else {
                    fileURLs.append(url)
                }
            }

            if !fileURLs.isEmpty {
                let result = await importService.importFiles(at: fileURLs)
                library.upsertTracks(result.tracks)
                importedTrackCount += result.tracks.count
                failureCount += result.failures.count
            }

            await persistLibrary()
            startPlaybackAnalysis()

            let sourceSummary = importedFolderCount > 0
                ? " from \(importedFolderCount) folder\(importedFolderCount == 1 ? "" : "s")"
                : ""
            if failureCount == 0 {
                statusMessage = "Imported \(importedTrackCount) track\(importedTrackCount == 1 ? "" : "s")\(sourceSummary)."
            } else {
                statusMessage = "Imported \(importedTrackCount) track\(importedTrackCount == 1 ? "" : "s")\(sourceSummary); \(failureCount) failed."
            }
        }
    }

    func importFolder(_ url: URL) {
        Task {
            isImporting = true
            defer { isImporting = false }

            do {
                let (folderSource, result) = try await importService.importFolder(at: url)
                library.upsertFolderSource(folderSource)
                library.upsertTracks(result.tracks)
                await persistLibrary()
                startPlaybackAnalysis()
                statusMessage = "Imported \(result.tracks.count) track\(result.tracks.count == 1 ? "" : "s") from \(url.lastPathComponent)."
            } catch {
                statusMessage = "Could not import folder: \(error.localizedDescription)"
            }
        }
    }

    func refreshOpenedFolders() {
        guard !library.folderSources.isEmpty else { return }

        Task {
            var importedCount = 0
            var didUpdateTracks = false
            for folderSource in library.folderSources {
                let folderURL = folderURL(for: folderSource)
                guard FileManager.default.fileExists(atPath: folderURL.path) else { continue }

                do {
                    let (updatedSource, result) = try await importService.importFolder(
                        at: folderURL,
                        recursive: folderSource.isRecursive
                    )
                    var sourceToStore = updatedSource
                    sourceToStore.id = folderSource.id
                    library.upsertFolderSource(sourceToStore)
                    let previousAlbumFingerprints = albumFingerprints(for: library.tracks)
                    let previousArtworkFingerprints = artworkFingerprints(for: library.tracks)
                    let previousTrackCount = library.tracks.count
                    library.upsertTracks(result.tracks)
                    if albumFingerprints(for: library.tracks) != previousAlbumFingerprints {
                        didUpdateTracks = true
                    }
                    if artworkFingerprints(for: library.tracks) != previousArtworkFingerprints {
                        didUpdateTracks = true
                    }
                    importedCount += max(library.tracks.count - previousTrackCount, 0)
                } catch {
                    statusMessage = "Could not refresh \(folderURL.lastPathComponent): \(error.localizedDescription)"
                }
            }

            if importedCount > 0 {
                statusMessage = "Added \(importedCount) new track\(importedCount == 1 ? "" : "s") from watched folders."
                await persistLibrary()
                startPlaybackAnalysis()
            } else if didUpdateTracks {
                statusMessage = "Updated album artwork from watched folders."
                await persistLibrary()
            }
        }
    }

    func play(_ track: Track) {
        play(track, within: sortedTracks)
    }

    func play(_ track: Track, within tracks: [Track], preloadLookaheadCount: Int = 1) {
        guard !tracks.isEmpty else { return }

        let index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        let requestID = UUID()

        playbackRequestID = requestID
        optimisticPlaybackTrackID = track.id

        Task { @MainActor in
            await Task.yield()
            guard playbackRequestID == requestID else { return }

            do {
                let items = tracks.map {
                    PlaybackQueueItem(
                        trackID: $0.id,
                        url: playbackURL(for: $0),
                        title: $0.title,
                        normalizationGain: $0.playbackNormalizationGain,
                        playbackEndTime: $0.playbackEndTime,
                        playbackAnalysisVersion: $0.playbackAnalysisVersion
                    )
                }
                try player.replaceQueue(
                    with: items,
                    startingAt: index,
                    autoplay: true,
                    preloadLookaheadCount: preloadLookaheadCount
                )
                if playbackRequestID == requestID {
                    optimisticPlaybackTrackID = nil
                }
                markPlayed(track)
            } catch {
                if playbackRequestID == requestID {
                    optimisticPlaybackTrackID = nil
                }
                statusMessage = error.localizedDescription
            }
        }
    }

    func playAlbum(_ album: LibraryAlbumGroup) {
        guard let firstTrack = album.tracks.first else { return }
        play(firstTrack, within: album.tracks, preloadLookaheadCount: album.tracks.count)
    }

    func playPlaylist(_ playlist: Playlist) {
        let tracks = tracks(for: playlist)
        guard let firstTrack = tracks.first else { return }
        play(firstTrack, within: tracks)
    }

    @discardableResult
    func createPlaylist(named name: String = "New Playlist") -> Playlist.ID {
        let playlist = library.createPlaylist(named: name)
        Task {
            await persistLibrary()
        }
        statusMessage = "Created \(playlist.name)."
        return playlist.id
    }

    @discardableResult
    func createPlaylist(named name: String = "New Playlist", adding track: Track) -> Playlist.ID {
        let playlist = library.createPlaylist(named: name)
        library.addTrack(track.id, toPlaylist: playlist.id)
        Task {
            await persistLibrary()
        }
        statusMessage = "Added \(track.title) to \(playlist.name)."
        return playlist.id
    }

    func renamePlaylist(id: Playlist.ID, to name: String) {
        library.renamePlaylist(id: id, to: name)
        Task {
            await persistLibrary()
        }
    }

    func deletePlaylist(id: Playlist.ID) {
        library.deletePlaylist(id: id)
        Task {
            await persistLibrary()
        }
        statusMessage = "Deleted playlist."
    }

    func add(_ track: Track, to playlist: Playlist) {
        library.addTrack(track.id, toPlaylist: playlist.id)
        Task {
            await persistLibrary()
        }
        statusMessage = "Added \(track.title) to \(playlist.name)."
    }

    func removePlaylistItem(_ item: PlaylistItem, from playlist: Playlist) {
        library.removePlaylistItem(id: item.id, fromPlaylist: playlist.id)
        Task {
            await persistLibrary()
        }
    }

    func movePlaylistItem(id itemID: PlaylistItem.ID, in playlist: Playlist, to index: Int) {
        guard library.movePlaylistItem(id: itemID, inPlaylist: playlist.id, to: index) else { return }
        Task {
            await persistLibrary()
        }
    }

    func enqueue(_ track: Track) {
        player.enqueue(
            url: playbackURL(for: track),
            trackID: track.id,
            title: track.title,
            normalizationGain: track.playbackNormalizationGain,
            playbackEndTime: track.playbackEndTime,
            playbackAnalysisVersion: track.playbackAnalysisVersion
        )
        statusMessage = "Added \(track.title) to the queue."
    }

    func playNext(_ track: Track) {
        player.playNext(
            url: playbackURL(for: track),
            trackID: track.id,
            title: track.title,
            normalizationGain: track.playbackNormalizationGain,
            playbackEndTime: track.playbackEndTime,
            playbackAnalysisVersion: track.playbackAnalysisVersion
        )
        statusMessage = "\(track.title) will play next."
    }

    func togglePlayback() {
        if player.state.isPlaying {
            player.pause()
        } else {
            do {
                try player.play()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func seek(to time: TimeInterval) {
        do {
            try player.seek(to: time)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func observePlaybackState() {
        playbackStateCancellable = player.$state.sink { [weak self] state in
            Task { @MainActor [weak self] in
                self?.playbackStateDidChange(state)
            }
        }
    }

    private func restorePlaybackIfNeeded(from loadedLibrary: LocalLibrary) {
        guard let resumeState = loadedLibrary.playbackResumeState,
              !loadedLibrary.queue.isEmpty,
              loadedLibrary.queue.currentItem != nil else { return }

        isRestoringPlayback = true
        defer { isRestoringPlayback = false }

        do {
            try player.restoreQueue(
                loadedLibrary.queue,
                currentTime: resumeState.currentTime,
                profile: resumeState.profile,
                repeatMode: resumeState.repeatMode,
                autoplay: resumeState.wasPlaying
            )
        } catch {
            statusMessage = "Could not restore playback: \(error.localizedDescription)"
        }
    }

    private func playbackStateDidChange(_ state: PlaybackState) {
        guard !isRestoringPlayback else { return }

        let snapshot = playbackResumeSnapshot(from: state)
        guard shouldSavePlaybackResumeSnapshot(snapshot) else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastPlaybackResumeSaveDate)
        if hasImmediatePlaybackResumeChange(snapshot) ||
            elapsed >= Self.playbackResumeSaveInterval ||
            !state.isPlaying ||
            snapshot.resumeState == nil {
            persistPlaybackResumeSnapshot(snapshot)
            return
        }

        guard playbackResumeSaveTask == nil else { return }
        let delay = max(Self.playbackResumeSaveInterval - elapsed, 0.5)
        playbackResumeSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.playbackResumeSaveTask = nil
            self.persistPlaybackResumeSnapshot(self.playbackResumeSnapshot(from: self.player.state))
        }
    }

    private func playbackResumeSnapshot(from state: PlaybackState) -> PlaybackResumeSnapshot {
        let currentTime = state.currentTime.isFinite ? max(state.currentTime, 0) : 0
        let resumeState: PlaybackResumeState?
        if state.queue.currentItem == nil || state.queue.isEmpty {
            resumeState = nil
        } else {
            resumeState = PlaybackResumeState(
                currentTime: currentTime,
                wasPlaying: state.isPlaying,
                repeatMode: state.repeatMode,
                profile: state.profile
            )
        }

        return PlaybackResumeSnapshot(queue: state.queue, resumeState: resumeState)
    }

    private func shouldSavePlaybackResumeSnapshot(_ snapshot: PlaybackResumeSnapshot) -> Bool {
        guard let lastSavedPlaybackResumeSnapshot else { return true }
        guard snapshot.queue == lastSavedPlaybackResumeSnapshot.queue else { return true }
        guard snapshot.resumeState?.wasPlaying == lastSavedPlaybackResumeSnapshot.resumeState?.wasPlaying,
              snapshot.resumeState?.repeatMode == lastSavedPlaybackResumeSnapshot.resumeState?.repeatMode,
              snapshot.resumeState?.profile == lastSavedPlaybackResumeSnapshot.resumeState?.profile else {
            return true
        }

        let savedTime = lastSavedPlaybackResumeSnapshot.resumeState?.currentTime ?? 0
        let currentTime = snapshot.resumeState?.currentTime ?? 0
        return abs(savedTime - currentTime) >= Self.playbackResumeSaveInterval
    }

    private func hasImmediatePlaybackResumeChange(_ snapshot: PlaybackResumeSnapshot) -> Bool {
        guard let lastSavedPlaybackResumeSnapshot else { return true }
        guard snapshot.queue == lastSavedPlaybackResumeSnapshot.queue else { return true }
        return snapshot.resumeState?.wasPlaying != lastSavedPlaybackResumeSnapshot.resumeState?.wasPlaying ||
            snapshot.resumeState?.repeatMode != lastSavedPlaybackResumeSnapshot.resumeState?.repeatMode ||
            snapshot.resumeState?.profile != lastSavedPlaybackResumeSnapshot.resumeState?.profile
    }

    private func persistPlaybackResumeSnapshot(_ snapshot: PlaybackResumeSnapshot) {
        playbackResumeSaveTask?.cancel()
        playbackResumeSaveTask = nil

        library.queue = snapshot.queue
        library.playbackResumeState = snapshot.resumeState
        lastSavedPlaybackResumeSnapshot = snapshot
        lastPlaybackResumeSaveDate = Date()

        Task {
            await persistLibrary()
        }
    }

    private func markPlayed(_ track: Track) {
        guard let index = library.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        library.tracks[index].lastPlayedDate = Date()
        library.tracks[index].playCount += 1
        Task {
            await persistLibrary()
        }
    }

    private func playbackURL(for track: Track) -> URL {
        guard let bookmarkData = track.bookmarkData else {
            return track.fileURL
        }

        var isStale = false
        if let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolvedURL
        }

        return track.fileURL
    }

    private func folderURL(for folderSource: FolderSource) -> URL {
        guard let bookmarkData = folderSource.bookmarkData else {
            return folderSource.folderURL
        }

        var isStale = false
        if let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolvedURL
        }

        return folderSource.folderURL
    }

    private func startFolderRefreshTimer() {
        folderRefreshTimer?.invalidate()
        folderRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOpenedFolders()
            }
        }
    }

    private func startPlaybackAnalysis() {
        playbackAnalysisTask?.cancel()

        let candidates = library.tracks
            .filter {
                $0.availability == .available &&
                    ($0.playbackNormalizationGain == nil || $0.playbackAnalysisVersion != PlaybackAnalysis.currentVersion)
            }
            .map { track in
                (id: track.id, url: playbackURL(for: track))
            }

        guard !candidates.isEmpty else { return }

        playbackAnalysisTask = Task(priority: .utility) { [weak self] in
            var pendingSaveCount = 0

            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let analysis = await PlaybackNormalizationAnalyzer.shared.analysis(for: candidate.url)
                guard let self, !Task.isCancelled else { return }
                guard let index = self.library.tracks.firstIndex(where: { $0.id == candidate.id }) else {
                    continue
                }
                guard self.library.tracks[index].playbackNormalizationGain == nil ||
                    self.library.tracks[index].playbackAnalysisVersion != PlaybackAnalysis.currentVersion else {
                    continue
                }

                self.library.tracks[index].playbackNormalizationGain = Double(analysis.normalization.linearGain)
                self.library.tracks[index].playbackEndTime = analysis.playbackEndTime
                self.library.tracks[index].playbackAnalysisVersion = PlaybackAnalysis.currentVersion
                pendingSaveCount += 1

                if pendingSaveCount >= Self.playbackAnalysisSaveBatchSize {
                    await self.persistLibrary()
                    pendingSaveCount = 0
                }

                try? await Task.sleep(nanoseconds: Self.playbackAnalysisThrottleNanoseconds)
                await Task.yield()
            }

            if pendingSaveCount > 0 {
                await self?.persistLibrary()
            }
        }
    }

    private func artworkFingerprints(for tracks: [Track]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tracks.map { track in
            let trackKey = track.fileURL.standardizedFileURL.path
            let artworkKey = [
                track.artworkURL?.standardizedFileURL.path,
                track.artworkCacheKey,
                track.artworkBookmarkData == nil ? "no-bookmark" : "bookmark"
            ]
            .compactMap { $0 }
            .joined(separator: "|")

            return (trackKey, artworkKey)
        })
    }

    private func albumFingerprints(for tracks: [Track]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tracks.map { track in
            let trackKey = track.fileURL.standardizedFileURL.path
            let albumKey = [
                track.album,
                track.albumArtist,
                track.releaseYear.map(String.init)
            ]
            .compactMap { $0 }
            .joined(separator: "|")

            return (trackKey, albumKey)
        })
    }

    private static func albumKey(for track: Track) -> String {
        track.fileURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func albumTitle(for track: Track) -> String {
        let album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        if album?.isEmpty == false {
            return album!
        }

        let folderName = track.fileURL.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return folderName.isEmpty ? "Unknown Album" : folderName
    }

    private static func isOnlineDownloadedTrack(_ track: Track) -> Bool {
        track.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/")
    }

    private static func isOnlineSingleDownloadTrack(_ track: Track) -> Bool {
        track.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/Tracks/")
    }

    private static func isOnlineAlbumDownloadTrack(_ track: Track) -> Bool {
        track.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/Albums/")
    }

    private static func albumTrackSort(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsDisc = lhs.discNumber ?? 0
        let rhsDisc = rhs.discNumber ?? 0
        if lhsDisc != rhsDisc {
            return lhsDisc < rhsDisc
        }

        let lhsTrack = lhs.trackNumber ?? Int.max
        let rhsTrack = rhs.trackNumber ?? Int.max
        if lhsTrack != rhsTrack {
            return lhsTrack < rhsTrack
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func persistLibrary() async {
        guard let store else { return }

        do {
            try await store.save(library)
        } catch {
            statusMessage = "Could not save library: \(error.localizedDescription)"
        }
    }

    private func rebuildLibraryCacheIfNeeded() {
        guard needsLibraryCacheRebuild else { return }

        var pathLookup: [String: Track] = [:]
        var idLookup: [Track.ID: Track] = [:]
        pathLookup.reserveCapacity(library.tracks.count)
        idLookup.reserveCapacity(library.tracks.count)

        for track in library.tracks {
            idLookup[track.id] = track

            let path = track.fileURL.standardizedFileURL.path
            if pathLookup[path] == nil {
                pathLookup[path] = track
            }
        }

        tracksByID = idLookup
        tracksByStandardizedPath = pathLookup
        sortedTracksCache = library.tracks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        albumGroupsCache = Dictionary(grouping: library.tracks.filter { !Self.isOnlineSingleDownloadTrack($0) }, by: Self.albumKey(for:))
            .map { key, tracks in
                let sortedAlbumTracks = tracks.sorted(by: Self.albumTrackSort)
                return LibraryAlbumGroup(
                    id: key,
                    title: sortedAlbumTracks.first.map(Self.albumTitle(for:)) ?? "Unknown Album",
                    tracks: sortedAlbumTracks
                )
            }
            .sorted {
                let artistComparison = $0.artistSummary.localizedCaseInsensitiveCompare($1.artistSummary)
                if artistComparison != .orderedSame {
                    return artistComparison == .orderedAscending
                }

                if let lhsYear = $0.releaseYear, let rhsYear = $1.releaseYear, lhsYear != rhsYear {
                    return lhsYear < rhsYear
                }

                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        recentlyAddedTracksCache = Array(library.tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(12))
        onlineDownloadedTracksCache = library.tracks
            .filter(Self.isOnlineSingleDownloadTrack)
            .sorted { $0.dateAdded > $1.dateAdded }
        needsLibraryCacheRebuild = false
    }
}

#if os(macOS)
private extension OnlineSearchResult.DownloadState {
    var isIdle: Bool {
        if case .idle = self {
            return true
        }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }
        return false
    }

    var completedFileURL: URL? {
        if case let .completed(fileURL) = self {
            return fileURL
        }
        return nil
    }
}
#endif

func formattedDuration(_ duration: TimeInterval?) -> String {
    guard let duration, duration.isFinite, duration > 0 else {
        return "--:--"
    }

    let totalSeconds = Int(duration.rounded())
    return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
}

func formattedSpeedAdjustedDuration(_ duration: TimeInterval?, playbackRate: Double) -> String {
    guard let duration, duration.isFinite, duration > 0 else {
        return "--:--"
    }

    return formattedDuration(duration / max(playbackRate, 0.01))
}

enum NightwingTheme {
    static let background = Color(red: 10 / 255, green: 18 / 255, blue: 33 / 255)
    static let sidebar = Color(red: 8 / 255, green: 14 / 255, blue: 26 / 255)
    static let panel = Color(red: 17 / 255, green: 28 / 255, blue: 47 / 255)
    static let panelElevated = Color(red: 26 / 255, green: 42 / 255, blue: 68 / 255)
    static let action = Color(red: 31 / 255, green: 214 / 255, blue: 255 / 255)
    static let rowHover = Color(red: 31 / 255, green: 98 / 255, blue: 145 / 255).opacity(0.30)
    static let divider = Color(red: 120 / 255, green: 198 / 255, blue: 255 / 255).opacity(0.20)
    static let glassTint = Color(red: 31 / 255, green: 214 / 255, blue: 255 / 255).opacity(0.06)
    static let glassElevatedTint = Color(red: 31 / 255, green: 214 / 255, blue: 255 / 255).opacity(0.11)
    static let glassPressedTint = Color(red: 31 / 255, green: 214 / 255, blue: 255 / 255).opacity(0.17)
    static let glassStroke = Color(red: 113 / 255, green: 220 / 255, blue: 255 / 255).opacity(0.28)
    static let glassInnerStroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 190 / 255, green: 207 / 255, blue: 221 / 255)
    static let warning = Color(red: 255 / 255, green: 170 / 255, blue: 56 / 255)

    static var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 15 / 255, green: 35 / 255, blue: 62 / 255),
                background
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

extension View {
    func nightwingGlass<S: InsettableShape>(_ shape: S, isElevated: Bool = false) -> some View {
        background(.ultraThinMaterial, in: shape)
            .background(isElevated ? NightwingTheme.glassElevatedTint : NightwingTheme.glassTint, in: shape)
            .overlay {
                shape
                    .stroke(NightwingTheme.glassStroke, lineWidth: 1)
            }
            .overlay {
                shape
                    .inset(by: 1)
                    .stroke(NightwingTheme.glassInnerStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(isElevated ? 0.28 : 0.18), radius: isElevated ? 18 : 12, y: isElevated ? 10 : 6)
    }
}

struct LibraryAlbumGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let tracks: [Track]

    var isOnlineDownloadedAlbum: Bool {
        tracks.contains { track in
            track.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/Albums/")
        }
    }

    var releaseYear: Int? {
        tracks.compactMap(\.releaseYear).min()
    }

    var artistSummary: String {
        let artists = tracks
            .compactMap { track in
                let artist = (track.albumArtist ?? track.artist)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return artist?.isEmpty == false ? artist : nil
            }
            .uniquedCaseInsensitive()

        if let artist = artists.first, artists.count == 1 {
            return artist
        }

        if artists.count > 1 {
            return "\(artists.count) artists"
        }

        return "Unknown Artist"
    }

    var trackCountText: String {
        "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    var durationText: String {
        let duration = tracks.compactMap(\.duration).reduce(0, +)
        return duration > 0 ? formattedDuration(duration) : "--:--"
    }

    func durationText(playbackRate: Double) -> String {
        let duration = tracks.compactMap(\.duration).reduce(0, +)
        return duration > 0 ? formattedSpeedAdjustedDuration(duration, playbackRate: playbackRate) : "--:--"
    }

    var artworkTrack: Track? {
        tracks.first { $0.artworkURL != nil || $0.artworkCacheKey != nil } ?? tracks.first
    }
}

struct PlaylistTrackEntry: Identifiable, Hashable {
    var id: PlaylistItem.ID { item.id }
    let item: PlaylistItem
    let track: Track
}

private extension Array where Element == String {
    func uniquedCaseInsensitive() -> [String] {
        var seen: Set<String> = []
        var values: [String] = []

        for value in self {
            let key = value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            values.append(value)
        }

        return values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}

struct NightwingArtworkPlaceholder: View {
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 8
    var systemImage = "music.note"

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(NightwingTheme.panelElevated)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: max(16, size * 0.32), weight: .semibold))
                    .foregroundStyle(NightwingTheme.secondaryText)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(NightwingTheme.divider, lineWidth: 1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct NightwingArtworkView: View {
    var track: Track? = nil
    var album: LibraryAlbumGroup? = nil
    var size: CGFloat
    var cornerRadius: CGFloat
    var systemImage = "music.note"

    @Environment(\.displayScale) private var environmentDisplayScale
    @State private var image: NightwingPlatformImage?

    private var artworkTrack: Track? {
        track ?? album?.artworkTrack
    }

    private var artworkIdentity: String {
        guard let artworkTrack else {
            return "placeholder-\(systemImage)"
        }

        return [
            artworkTrack.artworkURL?.standardizedFileURL.path,
            artworkTrack.artworkCacheKey,
            artworkTrack.fileURL.standardizedFileURL.path
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private var artworkTaskIdentity: String {
        "\(artworkIdentity)|\(targetPixelSize)"
    }

    private var targetPixelSize: Int {
        max(96, Int(ceil(size * displayScale)))
    }

    private var displayScale: CGFloat {
        max(environmentDisplayScale, 1)
    }

    var body: some View {
        ZStack {
            if let image {
                NightwingPlatformImageView(image: image)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                NightwingArtworkPlaceholder(size: size, cornerRadius: cornerRadius, systemImage: systemImage)
            }
        }
        .frame(width: size, height: size)
        .background(NightwingTheme.panelElevated)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(NightwingTheme.divider, lineWidth: 1)
        }
        .task(id: artworkTaskIdentity) {
            image = nil
            guard let artworkTrack else { return }

            let loadedImage = await NightwingArtworkLoader.image(
                for: artworkTrack,
                targetPixelSize: targetPixelSize,
                displayScale: displayScale
            )

            guard !Task.isCancelled else { return }
            image = loadedImage
        }
        .accessibilityHidden(true)
    }
}

private struct NightwingPlatformImageView: View {
    let image: NightwingPlatformImage

    var body: some View {
#if canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
#elseif canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
#endif
    }
}

private enum NightwingArtworkLoader {
    static func image(
        for track: Track?,
        targetPixelSize: Int,
        displayScale: CGFloat
    ) async -> NightwingPlatformImage? {
        guard let track else { return nil }

        if let artworkURL = resolvedURL(track.artworkURL, bookmarkData: track.artworkBookmarkData),
           let image = image(
            contentsOf: artworkURL,
            targetPixelSize: targetPixelSize,
            displayScale: displayScale
           ) {
            return image
        }

        return await embeddedArtworkImage(
            for: track,
            targetPixelSize: targetPixelSize,
            displayScale: displayScale
        )
    }

    private static func image(
        contentsOf url: URL,
        targetPixelSize: Int,
        displayScale: CGFloat
    ) -> NightwingPlatformImage? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return image(data: data, targetPixelSize: targetPixelSize, displayScale: displayScale)
    }

    private static func embeddedArtworkImage(
        for track: Track,
        targetPixelSize: Int,
        displayScale: CGFloat
    ) async -> NightwingPlatformImage? {
        guard track.artworkCacheKey != nil else { return nil }
        guard let fileURL = resolvedURL(track.fileURL, bookmarkData: track.bookmarkData) else { return nil }

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: fileURL)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let formatMetadata = (try? await asset.load(.metadata)) ?? []
        let metadataItems = commonMetadata + formatMetadata

        for item in metadataItems where isArtworkMetadataItem(item) {
            if let data = try? await item.load(.dataValue),
               let image = image(data: data, targetPixelSize: targetPixelSize, displayScale: displayScale) {
                return image
            }
        }

        return nil
    }

    private static func resolvedURL(_ url: URL?, bookmarkData: Data?) -> URL? {
        if let bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return resolvedURL
            }
        }

        return url
    }

    private static func image(
        data: Data,
        targetPixelSize: Int,
        displayScale: CGFloat
    ) -> NightwingPlatformImage? {
        if let downsampledImage = downsampledImage(
            data: data,
            targetPixelSize: targetPixelSize,
            displayScale: displayScale
        ) {
            return downsampledImage
        }

#if canImport(AppKit)
        return NSImage(data: data)
#elseif canImport(UIKit)
        return UIImage(data: data)
#else
        nil
#endif
    }

    private static func downsampledImage(
        data: Data,
        targetPixelSize: Int,
        displayScale: CGFloat
    ) -> NightwingPlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetPixelSize, 1)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let clampedScale = max(displayScale, 1)
#if canImport(AppKit)
        let pointSize = CGSize(
            width: CGFloat(cgImage.width) / clampedScale,
            height: CGFloat(cgImage.height) / clampedScale
        )
        return NSImage(cgImage: cgImage, size: pointSize)
#elseif canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: clampedScale, orientation: .up)
#else
        return nil
#endif
    }

    private static func isArtworkMetadataItem(_ item: AVMetadataItem) -> Bool {
        let key = [
            item.commonKey?.rawValue,
            item.identifier?.rawValue,
            item.keySpace?.rawValue,
            item.key as? String
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        return key.contains("artwork") || key.contains("cover")
    }
}

struct TrackRowView: View {
    let track: NightwingUITrack

    var body: some View {
        HStack(spacing: 12) {
            NightwingArtworkPlaceholder()

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(track.artist) - \(track.album)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if !track.isAvailable {
                Label("Relink", systemImage: "exclamationmark.triangle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("File unavailable")
            }

            Text(track.fileType.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            Text(track.durationText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {}
            Button("Add to Queue", systemImage: "text.badge.plus") {}
            Button("Add to Playlist", systemImage: "music.note.list") {}
            Divider()
            Button("Locate File", systemImage: "folder") {}
        }
    }
}

struct LibraryTrackRowView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            NightwingArtworkPlaceholder()

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(track.displayArtist) - \(track.displayAlbum)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if track.availability != .available {
                Label("Relink", systemImage: "exclamationmark.triangle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("File unavailable")
            }

            Text(track.fileType.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            Text(formattedDuration(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.play(track)
        }
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                appModel.playNext(track)
            }
            Button("Add to Queue", systemImage: "text.badge.plus") {
                appModel.enqueue(track)
            }
            Button("Add to Playlist", systemImage: "music.note.list") {}
            Divider()
            Button("Locate File", systemImage: "folder") {}
        }
    }
}

struct AlbumRowContentView: View {
    let album: LibraryAlbumGroup

    var body: some View {
        HStack(spacing: 12) {
            NightwingArtworkView(album: album, size: 46, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(album.artistSummary) - \(album.trackCountText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(album.durationText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}

struct AlbumHeaderView: View {
    let album: LibraryAlbumGroup

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            NightwingArtworkView(album: album, size: 120, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(album.artistSummary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(album.trackCountText) - \(album.durationText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }
}

struct AlbumTrackListRowView: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            Text(trackNumberText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            if track.availability != .available {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("File unavailable")
            }

            Text(track.fileType.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            Text(formattedDuration(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private var trackNumberText: String {
        track.trackNumber.map(String.init) ?? "-"
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    var showsQueue: Binding<Bool>?

    init(showsQueue: Binding<Bool>? = nil) {
        self.showsQueue = showsQueue
    }

    var body: some View {
#if os(macOS)
        desktopBar
#else
        mobileBar
#endif
    }

    private var currentDisplayTrack: Track? {
        appModel.currentDisplayTrack()
    }

    private var showsPauseState: Bool {
        player.state.isPlaying || appModel.isPlaybackStarting
    }

    private var currentTitle: String {
        if let currentDisplayTrack {
            return currentDisplayTrack.title
        }

        return player.state.currentItem?.title ?? "Nothing Playing"
    }

    private var currentSubtitle: String {
        if let track = currentDisplayTrack {
            return "\(track.displayArtist) - \(track.displayAlbum)"
        }

        if let url = player.state.currentItem?.url {
            return url.deletingLastPathComponent().lastPathComponent
        }

        return "Choose an album"
    }

    private var progressBinding: Binding<Double> {
        Binding {
            player.state.currentTime
        } set: { newValue in
            appModel.seek(to: newValue)
        }
    }

    private var trackSummary: some View {
        HStack(spacing: 12) {
            NightwingArtworkView(track: currentDisplayTrack, size: 48, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(currentTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NightwingTheme.primaryText)
                    .lineLimit(1)
                Text(currentSubtitle)
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var transportButtons: some View {
        HStack(spacing: 18) {
            PlaybackSpeedMenu()
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)

            ShuffleButton()

            Button {
                try? player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NightwingTheme.secondaryText)
            .accessibilityLabel("Previous")

            Button {
                appModel.togglePlayback()
            } label: {
                Image(systemName: showsPauseState ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NightwingTheme.primaryText)
            .accessibilityLabel(showsPauseState ? "Pause" : "Play")

            Button {
                try? player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NightwingTheme.secondaryText)
            .accessibilityLabel("Next")

            RepeatButton()

            PlaybackSpeedMenu()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            Text(formattedDuration(player.state.speedAdjustedCurrentTime))
                .frame(width: 44, alignment: .trailing)

            Slider(value: progressBinding, in: 0...max(player.state.duration, 1))
                .disabled(player.state.currentItem == nil)
                .accessibilityLabel("Playback position")

            Text(formattedDuration(player.state.speedAdjustedDuration))
                .frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(NightwingTheme.secondaryText)
    }

#if os(macOS)
    private var desktopBar: some View {
        HStack(spacing: 20) {
            trackSummary
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320, alignment: .leading)

            Spacer(minLength: 10)

            VStack(spacing: 6) {
                transportButtons
                progressRow
            }
            .frame(maxWidth: 620)

            Spacer(minLength: 10)

            HStack(spacing: 12) {
                if let showsQueue {
                    QueueToggleButton(showsQueue: showsQueue)
                }

                VolumeControlView(showsValue: false)
                    .frame(width: 170)
            }
            .frame(minWidth: 250, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(NightwingTheme.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(NightwingTheme.divider)
                .frame(height: 1)
        }
    }
#endif

    private var mobileBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                NightwingArtworkView(track: currentDisplayTrack, size: 42, cornerRadius: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTitle)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .lineLimit(1)

                    Text(currentSubtitle)
                        .font(.caption)
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    appModel.togglePlayback()
                } label: {
                    Image(systemName: showsPauseState ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPauseState ? "Pause" : "Play")

                Button {
                    try? player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .frame(width: 32, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.white.opacity(0.86))
                        .frame(width: proxy.size.width * mobileProgressFraction)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(Int(mobileProgressFraction * 100)) percent")
        }
        .background(NightwingTheme.panel)
    }

    private var mobileProgressFraction: CGFloat {
        guard player.state.duration > 0 else { return 0 }
        return CGFloat(min(max(player.state.currentTime / player.state.duration, 0), 1))
    }
}

struct PlaybackSpeedMenu: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var isPickerPresented = false

    var isCompact = false

    var body: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                PlaybackSpeedFormulaView(speed: player.state.profile.clampedSpeed, size: isCompact ? 12 : 13, weight: .bold)
                    .fixedSize()

                if !isCompact {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                }
            }
            .foregroundStyle(NightwingTheme.primaryText)
            .padding(.horizontal, isCompact ? 8 : 10)
            .frame(minHeight: isCompact ? 28 : 30)
            .background(.ultraThinMaterial, in: Capsule())
            .background(NightwingTheme.glassElevatedTint, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(NightwingTheme.glassStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PlaybackProfile.speedLabel(for: player.state.profile.clampedSpeed))
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            PlaybackSpeedPickerPopover {
                isPickerPresented = false
            }
            .environmentObject(player)
        }
    }
}

private struct PlaybackSpeedPickerPopover: View {
    @EnvironmentObject private var player: PlayerEngine

    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback Speed")
                .font(.caption.weight(.bold))
                .foregroundStyle(NightwingTheme.secondaryText)

            VStack(spacing: 2) {
                ForEach(PlaybackProfile.speedPresets) { preset in
                    Button {
                        player.setSpeedPreset(preset)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isSelected(preset) ? NightwingTheme.action : Color.clear)
                                .frame(width: 16)

                            PlaybackSpeedFormulaView(semitoneOffset: preset.semitoneOffset, size: 15, weight: .semibold)
                                .frame(width: 66, alignment: .leading)

                            Text(presetSubtitle(for: preset))
                                .font(.callout)
                                .foregroundStyle(NightwingTheme.primaryText)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .background(isSelected(preset) ? NightwingTheme.action.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: preset))
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func isSelected(_ preset: PlaybackSpeedPreset) -> Bool {
        abs(player.state.profile.clampedSpeed - preset.speed) <= 0.006
    }

    private func isDefaultPreset(_ preset: PlaybackSpeedPreset) -> Bool {
        preset.semitoneOffset == Int(PlaybackProfile.nightcorePitchSemitones)
    }

    private func presetSubtitle(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "Original"
        }

        return "\(preset.title) st\(isDefaultPreset(preset) ? " - Default" : "")"
    }

    private func accessibilityLabel(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "1 times, original"
        }

        return "\(PlaybackProfile.speedLabel(for: preset.speed)), \(preset.title) semitones\(isDefaultPreset(preset) ? ", default" : "")"
    }
}

private struct PlaybackSpeedFormulaView: View {
    private let formula: PlaybackSpeedFormula
    private let size: CGFloat
    private let weight: Font.Weight

    init(speed: Double, size: CGFloat = 13, weight: Font.Weight = .semibold) {
        formula = PlaybackSpeedFormula(speed: speed)
        self.size = size
        self.weight = weight
    }

    init(semitoneOffset: Int, size: CGFloat = 13, weight: Font.Weight = .semibold) {
        formula = PlaybackSpeedFormula(semitoneOffset: semitoneOffset)
        self.size = size
        self.weight = weight
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
            if formula.isApproximate {
                Text("≈")
                    .font(.system(size: size, weight: weight))
            }

            formulaBody

            Text("x")
                .font(.system(size: size, weight: weight))
        }
        .accessibilityLabel(formula.accessibilityLabel)
    }

    @ViewBuilder
    private var formulaBody: some View {
        switch formula.kind {
        case .one:
            Text("1")
                .font(.system(size: size, weight: weight))
        case .squareRootTwo:
            Text("√2")
                .font(.system(size: size, weight: weight))
        case .whole(let value):
            Text("\(value)")
                .font(.system(size: size, weight: weight))
        case .power(let numerator, let denominator):
            HStack(alignment: .top, spacing: 1) {
                Text("2")
                    .font(.system(size: size, weight: weight))

                if denominator == 1 {
                    Text("\(numerator)")
                        .font(.system(size: size * 0.62, weight: weight))
                        .baselineOffset(size * 0.36)
                } else {
                    VStack(spacing: 0) {
                        Text("\(numerator)")
                            .font(.system(size: size * 0.52, weight: weight))
                        Rectangle()
                            .frame(width: fractionRuleWidth(numerator: numerator, denominator: denominator), height: 0.8)
                        Text("\(denominator)")
                            .font(.system(size: size * 0.52, weight: weight))
                    }
                    .offset(y: -size * 0.34)
                }
            }
        }
    }

    private func fractionRuleWidth(numerator: Int, denominator: Int) -> CGFloat {
        CGFloat(max(String(numerator).count, String(denominator).count)) * size * 0.32 + 4
    }
}

private struct PlaybackSpeedFormula {
    enum Kind {
        case one
        case whole(Int)
        case squareRootTwo
        case power(numerator: Int, denominator: Int)
    }

    let kind: Kind
    let isApproximate: Bool

    init(speed: Double) {
        let clampedSpeed = min(max(speed, 0.25), 4.0)

        if let preset = PlaybackProfile.speedPreset(matching: clampedSpeed) {
            self.init(semitoneOffset: preset.semitoneOffset, isApproximate: false)
            return
        }

        let roundedWholeSpeed = clampedSpeed.rounded()
        if abs(clampedSpeed - roundedWholeSpeed) <= 0.006 {
            self.init(kind: .whole(Int(roundedWholeSpeed)), isApproximate: false)
            return
        }

        let roundedCents = Int((1200.0 * log2(clampedSpeed)).rounded())
        self.init(numerator: roundedCents, denominator: 1200, isApproximate: true)
    }

    init(semitoneOffset: Int, isApproximate: Bool = false) {
        self.init(numerator: semitoneOffset, denominator: 12, isApproximate: isApproximate)
    }

    private init(kind: Kind, isApproximate: Bool) {
        self.kind = kind
        self.isApproximate = isApproximate
    }

    private init(numerator: Int, denominator: Int, isApproximate: Bool) {
        let divisor = Self.greatestCommonDivisor(abs(numerator), abs(denominator))
        let simplifiedNumerator = numerator / divisor
        let simplifiedDenominator = denominator / divisor

        self.isApproximate = isApproximate

        if simplifiedNumerator == 0 {
            kind = .one
        } else if simplifiedNumerator == simplifiedDenominator {
            kind = .whole(2)
        } else if simplifiedNumerator == 1 && simplifiedDenominator == 2 {
            kind = .squareRootTwo
        } else {
            kind = .power(numerator: simplifiedNumerator, denominator: simplifiedDenominator)
        }
    }

    var accessibilityLabel: String {
        let prefix = isApproximate ? "approximately " : ""

        switch kind {
        case .one:
            return "\(prefix)1 times"
        case .whole(let value):
            return "\(prefix)\(value) times"
        case .squareRootTwo:
            return "\(prefix)root 2 times"
        case .power(let numerator, let denominator):
            if denominator == 1 {
                return "\(prefix)2 to the \(numerator) times"
            }

            return "\(prefix)2 to the \(numerator) over \(denominator) times"
        }
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs

        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }

        return max(a, 1)
    }
}

struct ShuffleButton: View {
    @EnvironmentObject private var player: PlayerEngine

    var isCompact = false

    var body: some View {
        Button {
            player.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: isCompact ? 14 : 16, weight: .semibold))
                .frame(width: isCompact ? 30 : 28, height: isCompact ? 30 : 28)
                .foregroundStyle(player.state.queue.isShuffled ? NightwingTheme.action : NightwingTheme.secondaryText)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(player.state.queue.isShuffled ? "Turn shuffle off" : "Turn shuffle on")
        .accessibilityValue(player.state.queue.isShuffled ? "On" : "Off")
        .help(player.state.queue.isShuffled ? "Shuffle is on" : "Shuffle album or playlist")
    }
}

struct RepeatButton: View {
    @EnvironmentObject private var player: PlayerEngine

    var isCompact = false

    var body: some View {
        Button {
            player.toggleRepeatMode()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "repeat")
                    .font(.system(size: isCompact ? 14 : 16, weight: .semibold))
                    .frame(width: isCompact ? 30 : 28, height: isCompact ? 30 : 28)

                if player.state.repeatMode == .one {
                    Text("1")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(NightwingTheme.background)
                        .frame(width: 11, height: 11)
                        .background(NightwingTheme.action, in: Circle())
                        .offset(x: 2, y: 2)
                }
            }
            .foregroundStyle(player.state.repeatMode == .none ? NightwingTheme.secondaryText : NightwingTheme.action)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(repeatAccessibilityLabel)
        .accessibilityValue(repeatAccessibilityValue)
        .help(repeatHelp)
    }

    private var repeatAccessibilityLabel: String {
        switch player.state.repeatMode {
        case .none:
            return "Turn repeat song on"
        case .one:
            return "Turn repeat song off"
        }
    }

    private var repeatAccessibilityValue: String {
        switch player.state.repeatMode {
        case .none:
            return "Queue loop"
        case .one:
            return "Repeat song"
        }
    }

    private var repeatHelp: String {
        switch player.state.repeatMode {
        case .none:
            return "Play through the album or playlist, then loop"
        case .one:
            return "Repeat current song"
        }
    }
}

struct QueueToggleButton: View {
    @Binding var showsQueue: Bool

    var body: some View {
        Button {
            showsQueue.toggle()
        } label: {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(showsQueue ? NightwingTheme.action : NightwingTheme.secondaryText)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showsQueue ? "Hide queue" : "Show queue")
        .accessibilityValue(showsQueue ? "Shown" : "Hidden")
        .help("Queue")
    }
}

struct VolumeControlView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var draftVolume: Double?
    @State private var isEditing = false

    var showsValue = true

    private var displayedVolume: Double {
        draftVolume ?? player.state.volume
    }

    private var volumeBinding: Binding<Double> {
        Binding {
            displayedVolume
        } set: { newValue in
            let clampedVolume = min(max(newValue, 0), 1)
            draftVolume = clampedVolume
            player.previewVolume(clampedVolume)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .foregroundStyle(NightwingTheme.secondaryText)
                .frame(width: 18)
                .accessibilityHidden(true)

            Slider(value: volumeBinding, in: 0...1, onEditingChanged: handleEditingChanged)
                .accessibilityLabel("Volume")

            if showsValue {
                Text("\(Int((displayedVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .onAppear {
            draftVolume = player.state.volume
        }
        .onChange(of: player.state.volume) { _, newVolume in
            guard !isEditing else { return }
            draftVolume = newVolume
        }
    }

    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing

        if editing {
            draftVolume = player.state.volume
        } else {
            player.setVolume(displayedVolume)
            draftVolume = player.state.volume
        }
    }

    private var volumeIcon: String {
        switch displayedVolume {
        case 0:
            return "speaker.slash.fill"
        case ..<0.35:
            return "speaker.wave.1.fill"
        case ..<0.7:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }
}

struct TransportControlsView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    private var showsPauseState: Bool {
        player.state.isPlaying || appModel.isPlaybackStarting
    }

    private var currentTimeBinding: Binding<Double> {
        Binding {
            player.state.currentTime
        } set: { newValue in
            appModel.seek(to: newValue)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Slider(value: currentTimeBinding, in: 0...max(player.state.duration, 1))
                .accessibilityLabel("Playback position")

            HStack {
                Text(formattedDuration(player.state.speedAdjustedCurrentTime))
                Spacer()
                Text("-\(formattedDuration(player.state.speedAdjustedRemainingTime))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 28) {
                PlaybackSpeedMenu()
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                ShuffleButton()

                Button {
                    try? player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Previous")

                Button {
                    appModel.togglePlayback()
                } label: {
                    Image(systemName: showsPauseState ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 58))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPauseState ? "Pause" : "Play")

                Button {
                    try? player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Next")

                RepeatButton()

                PlaybackSpeedMenu()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .buttonStyle(.plain)

            VolumeControlView()
                .frame(maxWidth: 320)
        }
    }
}

struct NightcoreControlPanel: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var isExpanded: Bool

    init(initiallyExpanded: Bool = true) {
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var nightcoreEnabled: Binding<Bool> {
        Binding {
            player.state.profile.isNightcoreEnabled
        } set: { newValue in
            player.setNightcoreEnabled(newValue)
        }
    }

    private var speed: Binding<Double> {
        Binding {
            player.state.profile.speed
        } set: { newValue in
            player.setSpeed(newValue)
        }
    }

    private var pitchOffset: Binding<Double> {
        Binding {
            player.state.profile.pitchSemitones
        } set: { newValue in
            player.setPitchOffset(semitones: newValue)
        }
    }

    private var pitchLinked: Binding<Bool> {
        Binding {
            player.state.profile.isPitchLinkedToSpeed
        } set: { newValue in
            player.setPitchLinkedToSpeed(newValue)
        }
    }

    private var pitchPreserved: Binding<Bool> {
        Binding {
            player.state.profile.isPitchPreserved
        } set: { newValue in
            player.setPitchPreserved(newValue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Label("Nightcore", systemImage: "sparkles")
                        .font(.headline)

                    Spacer(minLength: 8)

                    if player.state.profile.isNightcoreEnabled {
                        HStack(spacing: 4) {
                            Text("Speeding up by")
                                .font(.callout.weight(.semibold))
                            PlaybackSpeedFormulaView(speed: player.state.profile.clampedSpeed, size: 14, weight: .semibold)
                        }
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    } else {
                        Text("Original speed")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(NightwingTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse Nightcore controls" : "Expand Nightcore controls")

            if isExpanded {
                HStack {
                    Text("Enabled")
                        .font(.callout)
                    Spacer()
                    Toggle("Nightcore", isOn: nightcoreEnabled)
                        .labelsHidden()
                }

                NightcoreSpeedPresetGrid()

                LabeledContent("Custom speed") {
                    PlaybackSpeedFormulaView(speed: player.state.profile.clampedSpeed, size: 14, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                Slider(value: speed, in: 0.5...2.0)
                    .accessibilityLabel("Custom speed")

                LabeledContent("Pitch offset") {
                    Text("\(player.state.profile.pitchSemitones, specifier: "%+.1f") st")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: pitchOffset, in: -12...12)
                    .accessibilityLabel("Pitch offset")

                Toggle("Link pitch to speed", isOn: pitchLinked)
                Toggle("Preserve pitch", isOn: pitchPreserved)

                Text("Effective pitch: \(player.state.profile.effectivePitchSemitones, specifier: "%+.1f") semitones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct NightcoreSpeedPresetGrid: View {
    @EnvironmentObject private var player: PlayerEngine

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed preset")
                .font(.callout.weight(.semibold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(PlaybackProfile.speedPresets) { preset in
                    Button {
                        player.setSpeedPreset(preset)
                    } label: {
                        VStack(spacing: 2) {
                            PlaybackSpeedFormulaView(semitoneOffset: preset.semitoneOffset, size: 15, weight: .bold)
                                .lineLimit(1)

                            Text(presetSubtitle(for: preset))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isSelected(preset) ? .black.opacity(0.72) : NightwingTheme.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(isSelected(preset) ? .black : NightwingTheme.primaryText)
                        .background(isSelected(preset) ? NightwingTheme.action : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isDefaultPreset(preset) ? NightwingTheme.action.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: preset))
                }
            }
        }
    }

    private func isSelected(_ preset: PlaybackSpeedPreset) -> Bool {
        abs(player.state.profile.clampedSpeed - preset.speed) <= 0.006
    }

    private func isDefaultPreset(_ preset: PlaybackSpeedPreset) -> Bool {
        preset.semitoneOffset == Int(PlaybackProfile.nightcorePitchSemitones)
    }

    private func presetSubtitle(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "Original"
        }

        return "\(preset.title) st\(isDefaultPreset(preset) ? " default" : "")"
    }

    private func accessibilityLabel(for preset: PlaybackSpeedPreset) -> String {
        if isDefaultPreset(preset) {
            return "\(PlaybackProfile.speedLabel(for: preset.speed)), default speed, \(preset.title) semitones"
        }

        return "\(PlaybackProfile.speedLabel(for: preset.speed)), \(preset.title) semitones"
    }
}

struct QueueListView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        List {
            if player.state.queue.items.isEmpty {
                PlaceholderStateView(
                    title: "Queue Empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    message: "Tracks you play or add next will appear here."
                )
            } else {
                Section("Up Next") {
                    ForEach(player.state.queue.items) { item in
                        HStack(spacing: 12) {
                            NightwingArtworkView(track: appModel.track(for: item), size: 38, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title ?? item.url.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1)
                                Text(item.url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if item.id == player.state.currentItem?.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct PlaceholderStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(NightwingTheme.secondaryText)

            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(NightwingTheme.primaryText)

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(NightwingTheme.secondaryText)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NightwingTheme.background)
    }
}

struct LibraryPlaceholderView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @State private var searchText = ""
    @State private var showsFileImporter = false
#if os(macOS)
    @State private var showsFolderImporter = false
#endif

    var body: some View {
        List {
            if appModel.sortedTracks.isEmpty {
                PlaceholderStateView(
                    title: "No Music Yet",
                    systemImage: "music.note",
                    message: "Add local audio files to start building your Nightwing library."
                )
            } else {
                Section {
                    ForEach(appModel.filteredTracks(matching: searchText)) { track in
                        LibraryTrackRowView(track: track)
                    }
                } header: {
                    Text("Songs")
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search local music")
        .toolbar {
            Button("Add Files", systemImage: "plus") {
                showsFileImporter = true
            }
#if os(macOS)
            Button("Add Folder", systemImage: "folder.badge.plus") {
                showsFolderImporter = true
            }
#endif
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                appModel.importFiles(urls)
            }
        }
#if os(macOS)
        .fileImporter(
            isPresented: $showsFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let folderURL = urls.first {
                appModel.importFolder(folderURL)
            }
        }
#endif
    }
}

struct SearchPlaceholderView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @State private var searchText = ""

    var body: some View {
        List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PlaceholderStateView(
                    title: "Search Local Files",
                    systemImage: "magnifyingglass",
                    message: "Imported tracks, albums, artists, and playlists will appear here."
                )
            } else {
                ForEach(appModel.filteredTracks(matching: searchText)) { track in
                    LibraryTrackRowView(track: track)
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Song, artist, album")
    }
}

struct PlaylistsPlaceholderView: View {
    var body: some View {
        List {
            ForEach(NightwingSampleData.playlists) { playlist in
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playlist.name)
                        Text(playlist.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.tint)
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            Button("New Playlist", systemImage: "plus") {}
        }
    }
}

struct NowPlayingPlaceholderView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    private var currentDisplayTrack: Track? {
        appModel.currentDisplayTrack()
    }

    private var currentTitle: String {
        currentDisplayTrack?.title ?? player.state.currentItem?.title ?? "Nothing Playing"
    }

    private var currentSubtitle: String {
        if let currentDisplayTrack {
            return "\(currentDisplayTrack.displayArtist) - \(currentDisplayTrack.displayAlbum)"
        }

        return player.state.currentItem?.url.lastPathComponent ?? "Choose a local track from Library"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                NightwingArtworkView(track: currentDisplayTrack, size: 260, cornerRadius: 16)
                    .shadow(radius: 18, y: 8)

                VStack(spacing: 5) {
                    Text(currentTitle)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(currentSubtitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                TransportControlsView()

                NightcoreControlPanel()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Queue")
                        .font(.headline)
                    QueueListView()
                        .frame(minHeight: 180)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Now Playing")
    }
}
