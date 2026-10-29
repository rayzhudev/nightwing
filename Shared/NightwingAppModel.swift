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

enum LyricsModelState: Equatable {
    case checking
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)
}

struct LyricsLibraryGenerationProgress: Equatable {
    var completed: Int
    var total: Int
    var currentTrackTitle: String?
}

#if os(macOS)
struct OnlineDownloadActivity: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let progress: Double
}

private enum OnlineSearchPartialResult: Sendable {
    case tracks([OnlineSearchResult])
    case albums([OnlineAlbumSearchResult])
    case trackFailure(String)
    case albumFailure(String)
    case cancelled
}

private struct PendingOnlineTrackAction {
    let success: (Track) -> Void
    let failure: () -> Void
}

private struct OrderedOnlineQueueFill {
    let generation: UUID
    let playbackRequestID: UUID
    let totalCount: Int
    var nextIndex = 0
    var preparedTracks: [Int: Track] = [:]
    var failedIndexes: Set<Int> = []
}
#endif

@MainActor
final class NightwingAppModel: ObservableObject {
    private static let playbackAnalysisThrottleNanoseconds: UInt64 = 120_000_000
    private static let playbackAnalysisSaveBatchSize = 12
    private static let playbackResumeSaveInterval: TimeInterval = 5
    private static let pendingLibraryLyricsGenerationKey = "nightwing.pendingLibraryLyricsGeneration"
    private static let libraryLyricsBackfillVersionKey = "nightwing.libraryLyricsBackfillVersion"
    private static let currentLibraryLyricsBackfillVersion = 1

    @Published private(set) var library: LocalLibrary = .empty {
        didSet {
            if library.folderSources.map(\.folderURL) != oldValue.folderSources.map(\.folderURL) ||
                library.folderSources.map(\.bookmarkData) != oldValue.folderSources.map(\.bookmarkData) {
                updateFolderMonitor()
            }
            if library.tracks != oldValue.tracks {
                needsLibraryCacheRebuild = true
            }
        }
    }
    @Published var statusMessage: String?
    @Published var isImporting = false
    @Published private(set) var optimisticPlaybackTrackID: Track.ID?
    @Published private(set) var lyricsDocumentsByTrackID: [Track.ID: LyricsDocument] = [:]
    @Published private(set) var generatingLyricsTrackIDs: Set<Track.ID> = []
    @Published private(set) var lyricsModelState: LyricsModelState = .notDownloaded
    @Published private(set) var lyricsLibraryGenerationProgress: LyricsLibraryGenerationProgress?
    #if os(macOS)
    @Published private(set) var onlineSearchResults: [OnlineSearchResult] = []
    @Published private(set) var onlineAlbumResults: [OnlineAlbumSearchResult] = []
    @Published private(set) var isSearchingOnline = false
    @Published private(set) var onlineAlbumTracks: [OnlineAlbumSearchResult.ID: [OnlineSearchResult]] = [:]
    @Published private(set) var loadingOnlineAlbumIDs: Set<OnlineAlbumSearchResult.ID> = []
    @Published private(set) var onlineAlbumTrackErrors: [OnlineAlbumSearchResult.ID: String] = [:]
    @Published private(set) var onlineTrackDownloadStates: [OnlineSearchResult.ID: OnlineSearchResult.DownloadState] = [:]
    @Published private(set) var onlineAlbumDownloadStates: [OnlineAlbumSearchResult.ID: OnlineSearchResult.DownloadState] = [:]
    @Published private(set) var importingRemotePlaylistIDs: Set<String> = []
    #endif

    let player = PlayerEngine(profile: .nightcore)
    #if os(macOS)
    let musicServiceConnections = MusicServiceConnections()
    #endif

    private let importService = LibraryImportService()
    private let lyricsStore: LyricsSidecarStore?
    private let lyricsModelDownloadService: LyricsModelDownloadService?
    private let lyricsTranscriptionService: LyricsTranscriptionService
    private let canonicalLyricsService = CanonicalLyricsService()
    private var lyricsLoadTasks: [Track.ID: Task<Void, Never>] = [:]
    private var lyricsGenerationTasks: [Track.ID: Task<Void, Never>] = [:]
    private let lyricsQueue = LyricsGenerationQueue()
    @Published private(set) var queuedLyricsTrackIDs: [Track.ID] = []
    @Published private(set) var activeLyricsTrackID: Track.ID?
    @Published private(set) var libraryRecoveryMessage: String?
    @Published private(set) var libraryNeedsRecovery = false
    @Published private(set) var lyricsTranscriptionProgress: [Track.ID: Double] = [:]
    private var libraryLyricsGenerationTask: Task<Void, Never>?
    private var didLoadLibrary = false
    #if os(macOS)
    private let onlineSearchService = YtDlpDownloadService()
    private var onlineSearchTask: Task<Void, Never>?
    private var onlineSearchGeneration: UUID?
    private var pendingOnlineTrackActions: [OnlineSearchResult.ID: [PendingOnlineTrackAction]] = [:]
    private var onlineTrackDownloadTasks: [OnlineSearchResult.ID: Task<Void, Never>] = [:]
    private var onlineAlbumDownloadTasks: [OnlineAlbumSearchResult.ID: Task<Void, Never>] = [:]
    private var onlineTrackDownloadGenerations: [OnlineSearchResult.ID: UUID] = [:]
    private var onlineAlbumDownloadGenerations: [OnlineAlbumSearchResult.ID: UUID] = [:]
    private var onlineTrackDownloadMetadata: [OnlineSearchResult.ID: OnlineSearchResult] = [:]
    private var onlineAlbumDownloadMetadata: [OnlineAlbumSearchResult.ID: OnlineAlbumSearchResult] = [:]
    private var onlineAlbumTrackTasks: [OnlineAlbumSearchResult.ID: Task<Void, Never>] = [:]
    private var onlineAlbumTrackGenerations: [OnlineAlbumSearchResult.ID: UUID] = [:]
    private var onlineQueueGeneration: UUID?
    private var orderedOnlineQueueFill: OrderedOnlineQueueFill?
    private var onlineQueueSuggestionTask: Task<Void, Never>?
    private var temporaryOnlineTracksByID: [Track.ID: (track: Track, source: OnlineSearchResult)] = [:]
    #endif
    private let store: JSONLocalLibraryStore?
    private var folderMonitor: WatchedFolderMonitor?
    private var folderEventTask: Task<Void, Never>?
    private var folderRefreshPending = false
    private var folderRefreshTimer: Timer?
    private var folderRefreshTask: Task<Void, Never>?
    private var playbackAnalysisTask: Task<Void, Never>?
    private var playbackRequestID = UUID()
    private var playbackStateCancellable: AnyCancellable?
    private var playbackResumeSaveTask: Task<Void, Never>?
    private var lastPlaybackResumeSaveDate = Date.distantPast
    private var lastSavedPlaybackResumeSnapshot: PlaybackResumeSnapshot?
    private var isRestoringPlayback = false
    private var lastObservedPlaybackState: PlaybackState?
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
        lyricsStore = try? LyricsSidecarStore.defaultStore()
        let lyricsModelDownloadService = try? LyricsModelDownloadService.defaultService()
        self.lyricsModelDownloadService = lyricsModelDownloadService
        lyricsTranscriptionService = LyricsTranscriptionService(
            modelDownloadService: lyricsModelDownloadService
        )
        let savedVolume = NightwingEnvironment.defaults.double(forKey: "nightwing.defaultVolume")
        player.setVolume(savedVolume > 0 ? savedVolume : 0.85)
        lyricsQueue.stateChanged = { [weak self] in
            guard let self else { return }
            self.queuedLyricsTrackIDs = self.lyricsQueue.pendingIDs
            self.activeLyricsTrackID = self.lyricsQueue.activeID
        }
        observePlaybackState()
        Task {
            await loadLibrary()
            #if os(iOS)
            if didLoadLibrary { await importSystemMusicLibraryIfPossible(requestAuthorization: true, showStatus: true) }
            #endif
            refreshOpenedFolders()
        }
        refreshLyricsModelAvailability()
        startFolderRefreshTimer()
    }

    deinit {
        folderRefreshTimer?.invalidate()
        folderEventTask?.cancel()
        folderRefreshTask?.cancel()
        playbackAnalysisTask?.cancel()
        playbackStateCancellable?.cancel()
        playbackResumeSaveTask?.cancel()
        lyricsLoadTasks.values.forEach { $0.cancel() }
        lyricsGenerationTasks.values.forEach { $0.cancel() }
        libraryLyricsGenerationTask?.cancel()
        #if os(macOS)
        onlineSearchTask?.cancel()
        onlineTrackDownloadTasks.values.forEach { $0.cancel() }
        onlineAlbumDownloadTasks.values.forEach { $0.cancel() }
        onlineAlbumTrackTasks.values.forEach { $0.cancel() }
        onlineQueueSuggestionTask?.cancel()
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
            onlineSearchGeneration = nil
            onlineSearchTask = nil
            return
        }

        let generation = UUID()
        onlineSearchGeneration = generation
        isSearchingOnline = true
        let service = onlineSearchService

        onlineSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.onlineSearchGeneration == generation {
                    self.isSearchingOnline = false
                    self.onlineSearchTask = nil
                }
            }

            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, onlineSearchGeneration == generation else { return }

            var trackFailure: String?
            var albumFailure: String?
            await withTaskGroup(of: OnlineSearchPartialResult.self) { group in
                group.addTask {
                    do {
                        return .tracks(try await service.search(query: trimmedQuery))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .trackFailure(error.localizedDescription)
                    }
                }
                group.addTask {
                    do {
                        return .albums(try await service.searchAlbums(query: trimmedQuery))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .albumFailure(error.localizedDescription)
                    }
                }

                for await partialResult in group {
                    guard !Task.isCancelled, self.onlineSearchGeneration == generation else {
                        group.cancelAll()
                        return
                    }

                    switch partialResult {
                    case let .tracks(results):
                        let hydratedResults = await self.resultsWithCacheState(results)
                        guard self.onlineSearchGeneration == generation else { return }
                        self.onlineSearchResults = hydratedResults
                    case let .albums(albums):
                        let hydratedAlbums = await self.albumsWithDownloadState(albums)
                        guard self.onlineSearchGeneration == generation else { return }
                        self.onlineAlbumResults = hydratedAlbums
                    case let .trackFailure(message):
                        trackFailure = message
                    case let .albumFailure(message):
                        albumFailure = message
                    case .cancelled:
                        break
                    }
                }
            }

            if let trackFailure, let albumFailure,
               onlineSearchGeneration == generation,
               onlineSearchResults.isEmpty,
               onlineAlbumResults.isEmpty {
                statusMessage = "Online search failed: \(trackFailure); \(albumFailure)"
            }
        }
    }

    func clearOnlineSearchResults() {
        onlineSearchTask?.cancel()
        onlineSearchTask = nil
        onlineSearchGeneration = nil
        onlineSearchResults = []
        onlineAlbumResults = []
        isSearchingOnline = false
    }

    func getCachedTrack(hash: String) async -> CachedTrackEntry? {
        try? await onlineSearchService.getCachedEntry(sourceHash: hash)
    }

    func downloadOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result)
    }

    func deleteOnlineTrack(_ result: OnlineSearchResult) {
        let sourceHash = OnlineTrackStore.hashKey(for: result.sourceURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cached = try? await onlineSearchService.getCachedEntry(sourceHash: sourceHash)
            let fileURL: URL?
            if let cached {
                fileURL = URL(fileURLWithPath: cached.localFileURL)
            } else if case let .completed(completedURL) = onlineTrackDownloadState(for: result) {
                fileURL = completedURL
            } else {
                fileURL = nil
            }
            guard let fileURL else {
                setOnlineDownloadState(for: result.id, state: .idle)
                return
            }
            await deleteOnlineDownloadedFile(fileURL)
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

    func removeImportedAlbum(_ album: LibraryAlbumGroup) {
        let importedTracks = album.tracks.filter { !Self.isOnlineDownloadedTrack($0) }
        guard !importedTracks.isEmpty else { return }

        removeTrackIDsFromLiveQueue(Set(importedTracks.map(\.id)))
        library.removeImportedTracks(importedTracks)
        Task {
            await persistLibrary()
        }
        statusMessage = "Removed \(album.title) from the library. The original files were not deleted."
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
            cancelOnlineAlbumDownload(album)
            return
        }

        let generation = UUID()
        onlineAlbumDownloadGenerations[albumID] = generation
        onlineAlbumDownloadMetadata[albumID] = album
        setOnlineAlbumDownloadState(for: albumID, state: .downloading(progress: 0))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.onlineAlbumDownloadGenerations[albumID] == generation {
                    self.onlineAlbumDownloadTasks[albumID] = nil
                    self.onlineAlbumDownloadGenerations[albumID] = nil
                }
            }

            do {
                let albumFolderURL = try await onlineSearchService.downloadAlbum(album) { progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.onlineAlbumDownloadGenerations[albumID] == generation,
                              self.onlineAlbumDownloadStates[albumID]?.isDownloading == true else {
                            return
                        }
                        self.setOnlineAlbumDownloadState(for: albumID, state: .downloading(progress: progress))
                    }
                }

                try Task.checkCancellation()
                guard onlineAlbumDownloadGenerations[albumID] == generation else { return }
                setOnlineAlbumDownloadState(for: albumID, state: .completed(fileURL: albumFolderURL))
                await importDownloadedOnlineAlbum(albumFolderURL, fallback: album)
            } catch {
                guard onlineAlbumDownloadGenerations[albumID] == generation else { return }
                if error is CancellationError || Task.isCancelled {
                    setOnlineAlbumDownloadState(for: albumID, state: .idle)
                    statusMessage = "Cancelled album download."
                    return
                }
                setOnlineAlbumDownloadState(for: albumID, state: .failed(error.localizedDescription))
                statusMessage = "Album download failed: \(error.localizedDescription)"
            }
        }
        onlineAlbumDownloadTasks[albumID] = task
    }

    func loadOnlineAlbumTracks(_ album: OnlineAlbumSearchResult, force: Bool = false) {
        if !force, onlineAlbumTracks[album.id] != nil { return }
        if force {
            onlineAlbumTrackTasks[album.id]?.cancel()
        } else if onlineAlbumTrackTasks[album.id] != nil {
            return
        }

        let generation = UUID()
        onlineAlbumTrackGenerations[album.id] = generation
        loadingOnlineAlbumIDs.insert(album.id)
        onlineAlbumTrackErrors[album.id] = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if onlineAlbumTrackGenerations[album.id] == generation {
                    loadingOnlineAlbumIDs.remove(album.id)
                    onlineAlbumTrackTasks[album.id] = nil
                    onlineAlbumTrackGenerations[album.id] = nil
                }
            }
            do {
                let tracks = try await onlineSearchService.albumTracks(for: album)
                try Task.checkCancellation()
                guard onlineAlbumTrackGenerations[album.id] == generation else { return }
                onlineAlbumTracks[album.id] = await resultsWithCacheState(tracks)
                if tracks.isEmpty {
                    onlineAlbumTrackErrors[album.id] = "No preview tracks were returned for this album."
                }
            } catch is CancellationError {
                return
            } catch {
                guard onlineAlbumTrackGenerations[album.id] == generation else { return }
                onlineAlbumTrackErrors[album.id] = error.localizedDescription
            }
        }
        onlineAlbumTrackTasks[album.id] = task
    }

    func playOnlineAlbum(_ album: OnlineAlbumSearchResult) {
        let tracks = Array((onlineAlbumTracks[album.id] ?? []).prefix(12))
        guard let first = tracks.first else {
            loadOnlineAlbumTracks(album)
            return
        }

        let generation = beginOnlineQueueGeneration()
        prepareOnlineTrack(first) { [weak self] preparedTrack in
            guard let self,
                  self.onlineQueueGeneration == generation else { return }
            self.play(
                preparedTrack,
                within: [preparedTrack],
                preservingOnlineQueueGeneration: generation
            )
            let requestID = self.playbackRequestID
            self.startOrderedOnlineQueueFill(
                with: Array(tracks.dropFirst()),
                generation: generation,
                playbackRequestID: requestID
            )
        } failure: { [weak self] in
            self?.invalidateOnlineQueueGeneration(ifMatching: generation)
        }
    }

    func cancelOnlineAlbumDownload(_ album: OnlineAlbumSearchResult) {
        guard let task = onlineAlbumDownloadTasks[album.id] else { return }
        task.cancel()
        setOnlineAlbumDownloadState(for: album.id, state: .idle)
        statusMessage = "Cancelled album download."
        Task { [onlineSearchService] in
            await onlineSearchService.cancelAlbumDownload(album)
        }
    }

    func playOnlineTrack(_ result: OnlineSearchResult) {
        let generation = beginOnlineQueueGeneration()
        prepareOnlineTrack(result) { [weak self] track in
            guard let self,
                  self.onlineQueueGeneration == generation else { return }
            self.play(
                track,
                within: [track],
                preservingOnlineQueueGeneration: generation
            )
            self.enqueueSuggestedOnlineTracks(
                after: result,
                generation: generation,
                playbackRequestID: self.playbackRequestID
            )
        } failure: { [weak self] in
            self?.invalidateOnlineQueueGeneration(ifMatching: generation)
        }
    }

    func playNextOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result) { [weak self] track in
            self?.playNext(track)
        }
    }

    func enqueueOnlineTrack(_ result: OnlineSearchResult) {
        prepareOnlineTrack(result) { [weak self] track in
            self?.enqueue(track)
        }
    }

    private func enqueueSuggestedOnlineTracks(
        after seed: OnlineSearchResult,
        generation: UUID,
        playbackRequestID: UUID
    ) {
        onlineQueueSuggestionTask?.cancel()
        onlineQueueSuggestionTask = Task { @MainActor [weak self] in
            guard let self,
                  onlineQueueGeneration == generation,
                  self.playbackRequestID == playbackRequestID,
                  player.state.queue.items.count <= 1 else { return }

            do {
                let suggestions = try await onlineSearchService.suggestedTracks(after: seed, limit: 4)
                guard !Task.isCancelled,
                      onlineQueueGeneration == generation,
                      self.playbackRequestID == playbackRequestID,
                      player.state.queue.items.count <= 1 else { return }
                startOrderedOnlineQueueFill(
                    with: suggestions,
                    generation: generation,
                    playbackRequestID: playbackRequestID
                )
            } catch is CancellationError {
                return
            } catch {
                // Suggestions are opportunistic; playback of the requested song
                // must stay successful even if discovery is unavailable.
            }
        }
    }

    private func beginOnlineQueueGeneration() -> UUID {
        onlineQueueSuggestionTask?.cancel()
        onlineQueueSuggestionTask = nil
        orderedOnlineQueueFill = nil
        let generation = UUID()
        onlineQueueGeneration = generation
        return generation
    }

    private func invalidateOnlineQueueGeneration(ifMatching generation: UUID? = nil) {
        if let generation, onlineQueueGeneration != generation { return }
        onlineQueueSuggestionTask?.cancel()
        onlineQueueSuggestionTask = nil
        orderedOnlineQueueFill = nil
        onlineQueueGeneration = nil
    }

    private func startOrderedOnlineQueueFill(
        with results: [OnlineSearchResult],
        generation: UUID,
        playbackRequestID: UUID
    ) {
        guard onlineQueueGeneration == generation,
              self.playbackRequestID == playbackRequestID,
              !results.isEmpty else {
            return
        }

        orderedOnlineQueueFill = OrderedOnlineQueueFill(
            generation: generation,
            playbackRequestID: playbackRequestID,
            totalCount: results.count
        )

        for (index, result) in results.enumerated() {
            prepareOnlineTrack(result, addToLibrary: false) { [weak self] track in
                self?.recordPreparedOnlineQueueTrack(
                    track,
                    at: index,
                    generation: generation,
                    playbackRequestID: playbackRequestID
                )
            } failure: { [weak self] in
                self?.recordFailedOnlineQueueTrack(
                    at: index,
                    generation: generation,
                    playbackRequestID: playbackRequestID
                )
            }
        }
    }

    private func recordPreparedOnlineQueueTrack(
        _ track: Track,
        at index: Int,
        generation: UUID,
        playbackRequestID: UUID
    ) {
        guard var fill = orderedOnlineQueueFill,
              fill.generation == generation,
              fill.playbackRequestID == playbackRequestID else { return }
        fill.preparedTracks[index] = track
        orderedOnlineQueueFill = fill
        flushOrderedOnlineQueue(generation: generation, playbackRequestID: playbackRequestID)
    }

    private func recordFailedOnlineQueueTrack(
        at index: Int,
        generation: UUID,
        playbackRequestID: UUID
    ) {
        guard var fill = orderedOnlineQueueFill,
              fill.generation == generation,
              fill.playbackRequestID == playbackRequestID else { return }
        fill.failedIndexes.insert(index)
        orderedOnlineQueueFill = fill
        flushOrderedOnlineQueue(generation: generation, playbackRequestID: playbackRequestID)
    }

    private func flushOrderedOnlineQueue(generation: UUID, playbackRequestID: UUID) {
        guard onlineQueueGeneration == generation,
              self.playbackRequestID == playbackRequestID,
              var fill = orderedOnlineQueueFill,
              fill.generation == generation,
              fill.playbackRequestID == playbackRequestID else {
            invalidateOnlineQueueGeneration(ifMatching: generation)
            return
        }

        while fill.nextIndex < fill.totalCount {
            if let track = fill.preparedTracks.removeValue(forKey: fill.nextIndex) {
                enqueue(track)
                fill.nextIndex += 1
            } else if fill.failedIndexes.remove(fill.nextIndex) != nil {
                fill.nextIndex += 1
            } else {
                break
            }
        }

        orderedOnlineQueueFill = fill.nextIndex == fill.totalCount ? nil : fill
    }

    private func prepareOnlineTrack(
        _ result: OnlineSearchResult,
        addToLibrary: Bool = true,
        completion: ((Track) -> Void)? = nil,
        failure: (() -> Void)? = nil
    ) {
        let sourceID = result.id
        let action = (completion != nil || failure != nil)
            ? PendingOnlineTrackAction(
                success: { track in completion?(track) },
                failure: { failure?() }
            )
            : nil

        if case let .completed(fileURL) = onlineTrackDownloadState(for: result) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let track = await preparedOnlineTrack(
                    from: fileURL,
                    fallback: result,
                    addToLibrary: addToLibrary
                ) {
                    action?.success(track)
                } else {
                    action?.failure()
                }
            }
            return
        }

        if onlineTrackDownloadTasks[sourceID] != nil {
            if let action {
                appendPendingOnlineTrackAction(action, for: sourceID)
            }
            setOnlineDownloadState(for: sourceID, state: onlineTrackDownloadStates[sourceID] ?? .downloading(progress: 0))
            return
        }

        if let action {
            appendPendingOnlineTrackAction(action, for: sourceID)
        }

        let generation = UUID()
        onlineTrackDownloadGenerations[sourceID] = generation
        onlineTrackDownloadMetadata[sourceID] = result
        setOnlineDownloadState(for: sourceID, state: .downloading(progress: 0))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.onlineTrackDownloadGenerations[sourceID] == generation {
                    self.onlineTrackDownloadTasks[sourceID] = nil
                    self.onlineTrackDownloadGenerations[sourceID] = nil
                }
            }

            do {
                let fileURL = try await onlineSearchService.download(result) { progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.onlineTrackDownloadGenerations[sourceID] == generation,
                              self.onlineTrackDownloadStates[sourceID]?.isDownloading == true else {
                            return
                        }
                        self.setOnlineDownloadState(for: sourceID, state: .downloading(progress: progress))
                    }
                }

                try Task.checkCancellation()
                guard onlineTrackDownloadGenerations[sourceID] == generation else { return }
                setOnlineDownloadState(for: sourceID, state: .completed(fileURL: fileURL))
                if let track = await preparedOnlineTrack(
                    from: fileURL,
                    fallback: result,
                    addToLibrary: addToLibrary
                ) {
                    runPendingOnlineTrackActions(for: sourceID, track: track)
                } else {
                    failPendingOnlineTrackActions(for: sourceID)
                }
            } catch {
                guard onlineTrackDownloadGenerations[sourceID] == generation else { return }
                failPendingOnlineTrackActions(for: sourceID)
                if error is CancellationError || Task.isCancelled {
                    setOnlineDownloadState(for: sourceID, state: .idle)
                } else {
                    setOnlineDownloadState(for: sourceID, state: .failed(error.localizedDescription))
                    statusMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
        onlineTrackDownloadTasks[sourceID] = task
    }

    private func runPendingOnlineTrackActions(for id: OnlineSearchResult.ID, track: Track) {
        let actions = pendingOnlineTrackActions.removeValue(forKey: id) ?? []
        for action in actions {
            action.success(track)
        }
    }

    private func failPendingOnlineTrackActions(for id: OnlineSearchResult.ID) {
        let actions = pendingOnlineTrackActions.removeValue(forKey: id) ?? []
        for action in actions {
            action.failure()
        }
    }

    private func appendPendingOnlineTrackAction(_ action: PendingOnlineTrackAction, for id: OnlineSearchResult.ID) {
        pendingOnlineTrackActions[id, default: []].append(action)
    }

    func onlineTrackDownloadState(for result: OnlineSearchResult) -> OnlineSearchResult.DownloadState {
        if let state = onlineTrackDownloadStates[result.id] {
            return state
        }
        if let visibleResult = onlineSearchResults.first(where: { $0.id == result.id }) {
            return visibleResult.downloadState
        }
        return result.downloadState
    }

    func onlineAlbumDownloadState(for album: OnlineAlbumSearchResult) -> OnlineSearchResult.DownloadState {
        if let state = onlineAlbumDownloadStates[album.id] {
            return state
        }
        if let visibleAlbum = onlineAlbumResults.first(where: { $0.id == album.id }) {
            return visibleAlbum.downloadState
        }
        return album.downloadState
    }

    var activeOnlineDownloads: [OnlineDownloadActivity] {
        let tracks = onlineTrackDownloadStates.compactMap { id, state -> OnlineDownloadActivity? in
            guard case let .downloading(progress) = state,
                  let result = onlineTrackDownloadMetadata[id] else { return nil }
            return OnlineDownloadActivity(
                id: "track-\(id)",
                title: result.title,
                subtitle: result.artist ?? "Song",
                progress: progress
            )
        }
        let albums = onlineAlbumDownloadStates.compactMap { id, state -> OnlineDownloadActivity? in
            guard case let .downloading(progress) = state,
                  let album = onlineAlbumDownloadMetadata[id] else { return nil }
            return OnlineDownloadActivity(
                id: "album-\(id)",
                title: album.title,
                subtitle: album.artist ?? "Album",
                progress: progress
            )
        }
        return (tracks + albums).sorted {
            if $0.title != $1.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private func setOnlineDownloadState(for id: OnlineSearchResult.ID, state: OnlineSearchResult.DownloadState) {
        if state.isIdle {
            onlineTrackDownloadStates[id] = nil
        } else {
            onlineTrackDownloadStates[id] = state
        }
        if !state.isDownloading {
            onlineTrackDownloadMetadata[id] = nil
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
        if !state.isDownloading {
            onlineAlbumDownloadMetadata[id] = nil
        }

        guard let index = onlineAlbumResults.firstIndex(where: { $0.id == id }) else { return }
        onlineAlbumResults[index].downloadState = state
    }

    private func deleteOnlineDownloadedFile(_ fileURL: URL) async {
        let standardizedURL = fileURL.standardizedFileURL
        let tracksToRemove = library.tracks.filter {
            $0.fileURL.standardizedFileURL.path == standardizedURL.path
        }

        let path = standardizedURL.path
        let onlineTracksMarker = "/Nightwing/Online Downloads/Tracks/"
        let deleteURL: URL
        if path.contains(onlineTracksMarker) {
            deleteURL = standardizedURL.deletingLastPathComponent()
        } else {
            deleteURL = standardizedURL
        }

        guard isInsideOnlineDownloads(deleteURL) else {
            statusMessage = "Refused to delete a file outside Nightwing's download folder."
            return
        }

        do {
            if FileManager.default.fileExists(atPath: deleteURL.path) {
                try FileManager.default.removeItem(at: deleteURL)
            }
        } catch {
            statusMessage = "Could not delete online download: \(error.localizedDescription)"
            return
        }

        var cacheCleanupError: Error?
        do {
            _ = try await onlineSearchService.removeCachedEntry(localFileURL: standardizedURL)
        } catch {
            cacheCleanupError = error
        }

        removeTrackIDsFromLiveQueue(Set(tracksToRemove.map(\.id)))
        for track in tracksToRemove {
            library.deleteTrack(id: track.id)
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
        await persistLibrary()
        statusMessage = cacheCleanupError == nil
            ? "Deleted online download."
            : "Deleted online download; cache metadata will be repaired on the next download."
    }

    private func deleteOnlineDownloadedAlbumFolder(_ folderURL: URL, tracks: [Track]) async {
        let standardizedURL = folderURL.standardizedFileURL

        guard isInsideOnlineDownloads(standardizedURL) else {
            statusMessage = "Refused to delete a folder outside Nightwing's download folder."
            return
        }

        do {
            if FileManager.default.fileExists(atPath: standardizedURL.path) {
                try FileManager.default.removeItem(at: standardizedURL)
            }
        } catch {
            statusMessage = "Could not delete online album download: \(error.localizedDescription)"
            return
        }

        removeTrackIDsFromLiveQueue(Set(tracks.map(\.id)))
        for track in tracks {
            library.deleteTrack(id: track.id)
        }
        clearCompletedDownloadStates(matchingDeletedURL: standardizedURL, originalURL: standardizedURL)
        for albumIndex in onlineAlbumResults.indices {
            if completedDownloadState(onlineAlbumResults[albumIndex].downloadState, matchesDeletedURL: standardizedURL, originalURL: standardizedURL) {
                onlineAlbumResults[albumIndex].downloadState = .idle
            }
        }
        await persistLibrary()
        statusMessage = "Deleted online album download."
    }

    private func isInsideOnlineDownloads(_ url: URL) -> Bool {
        let basePath = YtDlpDownloadService.downloadsBaseURL().standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath.hasPrefix(basePath + "/")
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

    private func preparedOnlineTrack(
        from fileURL: URL,
        fallback result: OnlineSearchResult,
        addToLibrary: Bool
    ) async -> Track? {
        if addToLibrary {
            return await importDownloadedOnlineTrack(fileURL, fallback: result)
        }

        if let existingTrack = library.tracks.first(where: {
            $0.fileURL.standardizedFileURL.path == fileURL.standardizedFileURL.path
        }) {
            return existingTrack
        }

        guard let track = onlineTrack(from: fileURL, fallback: result) else {
            return nil
        }
        temporaryOnlineTracksByID[track.id] = (track, result)
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

        guard let items = MPMediaQuery.songs().items else {
            if showStatus {
                statusMessage = "Could not read the iPhone Music library."
            }
            return
        }
        let tracks = items.compactMap(systemMusicTrack)
        let existingSystemTracks = library.tracks.filter(Self.isSystemMusicTrack)
        let existingURLs = Set(existingSystemTracks.map { $0.fileURL.absoluteString })
        let currentURLs = Set(tracks.map { $0.fileURL.absoluteString })
        let staleTracks = existingSystemTracks.filter { !currentURLs.contains($0.fileURL.absoluteString) }
        removeTrackIDsFromLiveQueue(Set(staleTracks.map(\.id)))
        for track in staleTracks {
            library.deleteTrack(id: track.id)
        }

        let importedCount = tracks.filter { !existingURLs.contains($0.fileURL.absoluteString) }.count
        library.upsertTracks(tracks)
        await persistLibrary()
        if !tracks.isEmpty {
            startPlaybackAnalysis()
        }

        if showStatus {
            if importedCount > 0 {
                statusMessage = "Imported \(importedCount) iPhone Music track\(importedCount == 1 ? "" : "s")."
            } else if tracks.isEmpty {
                statusMessage = "No locally playable iPhone Music songs were found."
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

    private static func isSystemMusicTrack(_ track: Track) -> Bool {
        track.fileURL.scheme?.lowercased() == "ipod-library"
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

        #if os(macOS)
        if let trackID = item.trackID,
           let temporaryTrack = temporaryOnlineTracksByID[trackID]?.track {
            return temporaryTrack
        }
        #endif

        return tracksByStandardizedPath[item.url.standardizedFileURL.path]
    }

    func track(id: Track.ID) -> Track? {
        rebuildLibraryCacheIfNeeded()
        #if os(macOS)
        return tracksByID[id] ?? temporaryOnlineTracksByID[id]?.track
        #else
        return tracksByID[id]
        #endif
    }

    func currentDisplayTrack() -> Track? {
        if let optimisticPlaybackTrackID,
           let track = track(id: optimisticPlaybackTrackID) {
            return track
        }

        return track(for: player.state.currentItem)
    }

    func lyricsDocument(for track: Track?) -> LyricsDocument? {
        guard let track else { return nil }
        return lyricsDocumentsByTrackID[track.id]
    }

    func isGeneratingLyrics(for track: Track?) -> Bool {
        guard let track else { return false }
        return generatingLyricsTrackIDs.contains(track.id)
    }

    var lyricsModelDisplayName: String {
        "Whisper Small"
    }

    var lyricsModelDownloadBytes: Int64 {
        LyricsModelDownloadService.defaultModelDownloadBytes
    }

    var lyricsModelSizeText: String {
        ByteCountFormatter.string(fromByteCount: lyricsModelDownloadBytes, countStyle: .decimal)
    }

    func lyricsModelDownloadedSizeText(progress: Double) -> String {
        let downloadedBytes = Int64((Double(lyricsModelDownloadBytes) * min(max(progress, 0), 1)).rounded())
        return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .decimal)
    }

    func refreshLyricsModelAvailability() {
        #if os(macOS)
        switch lyricsModelState {
        case .checking, .downloading, .ready:
            return
        case .notDownloaded, .failed:
            break
        }
        lyricsModelState = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let lyricsModelDownloadService else {
                lyricsModelState = .failed("Nightwing could not prepare the lyrics model download.")
                return
            }
            if await lyricsModelDownloadService.availableModelURL() == nil {
                lyricsModelState = .notDownloaded
            } else {
                lyricsModelState = .ready
                startPendingLibraryLyricsGenerationIfNeeded()
            }
        }
        #endif
    }

    func downloadLyricsModel() {
        #if os(macOS)
        if case .downloading = lyricsModelState { return }
        guard let lyricsModelDownloadService else {
            lyricsModelState = .failed("Nightwing could not prepare the lyrics model download.")
            return
        }

        lyricsModelState = .downloading(progress: 0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await lyricsModelDownloadService.ensureModelAvailable { progress in
                    Task { @MainActor [weak self] in
                        self?.lyricsModelState = .downloading(progress: progress)
                    }
                }
                lyricsModelState = .ready
                NightwingEnvironment.defaults.set(true, forKey: Self.pendingLibraryLyricsGenerationKey)
                statusMessage = "The lyrics model is ready. Preparing your library..."
                startPendingLibraryLyricsGenerationIfNeeded()
            } catch is CancellationError {
                lyricsModelState = .notDownloaded
            } catch {
                lyricsModelState = .failed(error.localizedDescription)
                statusMessage = "Could not download the lyrics model: \(error.localizedDescription)"
            }
        }
        #endif
    }

    private func startPendingLibraryLyricsGenerationIfNeeded() {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              didLoadLibrary,
              lyricsModelState == .ready,
              (NightwingEnvironment.defaults.bool(forKey: Self.pendingLibraryLyricsGenerationKey) ||
                NightwingEnvironment.defaults.integer(forKey: Self.libraryLyricsBackfillVersionKey) < Self.currentLibraryLyricsBackfillVersion),
              libraryLyricsGenerationTask == nil else { return }

        NightwingEnvironment.defaults.set(true, forKey: Self.pendingLibraryLyricsGenerationKey)

        let tracks = library.tracks.filter { track in
            track.availability == .available && track.lyricsMetadata?.status != .ready
        }
        guard !tracks.isEmpty else {
            NightwingEnvironment.defaults.set(false, forKey: Self.pendingLibraryLyricsGenerationKey)
            NightwingEnvironment.defaults.set(Self.currentLibraryLyricsBackfillVersion, forKey: Self.libraryLyricsBackfillVersionKey)
            statusMessage = "Your library already has lyrics."
            return
        }

        lyricsLibraryGenerationProgress = LyricsLibraryGenerationProgress(
            completed: 0,
            total: tracks.count,
            currentTrackTitle: nil
        )
        libraryLyricsGenerationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = 0
            for track in tracks {
                guard !Task.isCancelled else { return }
                if self.library.tracks.first(where: { $0.id == track.id })?.lyricsMetadata?.status == .ready {
                    completed += 1
                    continue
                }
                self.lyricsLibraryGenerationProgress = LyricsLibraryGenerationProgress(
                    completed: completed,
                    total: tracks.count,
                    currentTrackTitle: track.title
                )
                self.generateLyrics(for: track, priority: false)
                if let generationTask = self.lyricsGenerationTasks[track.id] {
                    await generationTask.value
                }
                completed += 1
            }

            let generatedCount = tracks.filter { track in
                self.library.tracks.first(where: { $0.id == track.id })?.lyricsMetadata?.status == .ready
            }.count
            let failedCount = tracks.count - generatedCount
            self.lyricsLibraryGenerationProgress = nil
            self.libraryLyricsGenerationTask = nil
            NightwingEnvironment.defaults.set(false, forKey: Self.pendingLibraryLyricsGenerationKey)
            NightwingEnvironment.defaults.set(Self.currentLibraryLyricsBackfillVersion, forKey: Self.libraryLyricsBackfillVersionKey)
            self.statusMessage = failedCount == 0
                ? "Generated lyrics for \(generatedCount) songs in your library."
                : "Generated lyrics for \(generatedCount) songs. \(failedCount) could not be completed."
        }
        #endif
    }

    func loadLyricsIfAvailable(for track: Track?) {
        guard let track,
              lyricsDocumentsByTrackID[track.id] == nil,
              lyricsLoadTasks[track.id] == nil,
              let lyricsStore else {
            return
        }

        let sourceURL = playbackURL(for: track)
        let cacheKey = track.lyricsMetadata?.cacheKey ?? lyricsCacheKey(for: track, sourceURL: sourceURL)

        lyricsLoadTasks[track.id] = Task { @MainActor [weak self] in
            defer {
                self?.lyricsLoadTasks[track.id] = nil
            }

            do {
                if track.lyricsMetadata?.status == .ready,
                   let document = try await lyricsStore.load(cacheKey: cacheKey) {
                    if document.matchesSource(at: sourceURL) {
                        self?.lyricsDocumentsByTrackID[track.id] = document
                        return
                    } else {
                        try await lyricsStore.delete(cacheKey: cacheKey)
                        self?.updateLyricsMetadata(
                            trackID: track.id,
                            metadata: LyricsMetadata(cacheKey: cacheKey, status: .none)
                        )
                        await self?.persistLibrary()
                        self?.statusMessage = "Lyrics need to be regenerated because the audio changed."
                    }
                }

                #if os(iOS)
                guard NightwingEnvironment.defaults.bool(forKey: "nightwing.automaticallyLookupSyncedLyrics"),
                      let canonical = try await self?.canonicalLyricsService.lyrics(for: track),
                      case .synced(let lines) = canonical,
                      !lines.isEmpty else { return }
                let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let document = LyricsDocument(
                    trackID: track.id,
                    trackTitle: track.title,
                    artist: track.artist,
                    album: track.album,
                    sourceFilePath: sourceURL.standardizedFileURL.path,
                    sourceFileSize: values?.fileSize.map(Int64.init),
                    sourceModifiedAt: values?.contentModificationDate,
                    modelName: "LRCLIB synced lyrics",
                    transcriptionSpeed: 1,
                    lines: lines
                )
                try await lyricsStore.save(document, cacheKey: cacheKey)
                self?.lyricsDocumentsByTrackID[track.id] = document
                self?.updateLyricsMetadata(
                    trackID: track.id,
                    metadata: LyricsMetadata(
                        cacheKey: cacheKey,
                        status: .ready,
                        generatedAt: document.generatedAt,
                        modelName: document.modelName
                    )
                )
                await self?.persistLibrary()
                #endif
            } catch {
                self?.statusMessage = "Could not load lyrics: \(error.localizedDescription)"
            }
        }
    }

    func prepareLyricsForDisplay(for track: Track?) async {
        guard let track else { return }
        loadLyricsIfAvailable(for: track)
        await lyricsLoadTasks[track.id]?.value
        guard !Task.isCancelled, lyricsDocumentsByTrackID[track.id] == nil else { return }
        #if os(macOS)
        generateLyrics(for: track)
        #endif
    }

    func generateLyrics(for track: Track, priority: Bool = true) {
        guard lyricsGenerationTasks[track.id] == nil else {
            if priority { lyricsQueue.promote(track.id) }
            statusMessage = "Lyrics are already being generated for \(track.title)."
            return
        }

        guard let lyricsStore else {
            statusMessage = "Could not create a lyrics store."
            return
        }

        let sourceURL = playbackURL(for: track)
        let cacheKey = lyricsCacheKey(for: track, sourceURL: sourceURL)
        generatingLyricsTrackIDs.insert(track.id)
        lyricsGenerationTasks[track.id] = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.lyricsQueue.release(track.id)
                self.lyricsTranscriptionProgress[track.id] = nil
                self.generatingLyricsTrackIDs.remove(track.id)
                self.lyricsGenerationTasks[track.id] = nil
            }

            do {
                try await self.lyricsQueue.acquire(track.id, priority: priority)
                try Task.checkCancellation()
                self.statusMessage = "Generating lyrics for \(track.title)..."
                let document = try await self.lyricsTranscriptionService.transcribe(
                    track: track,
                    sourceURL: sourceURL,
                    lookupOnline: NightwingEnvironment.defaults.bool(forKey: "nightwing.automaticallyLookupSyncedLyrics"),
                    onModelDownloadProgress: { progress in
                        Task { @MainActor [weak self] in
                            guard self?.activeLyricsTrackID == track.id else { return }
                            self?.lyricsModelState = progress < 1 ? .downloading(progress: progress) : .ready
                        }
                    },
                    onTranscriptionProgress: { progress in
                        Task { @MainActor [weak self] in
                            guard self?.isGeneratingLyrics(for: track) == true else { return }
                            self?.lyricsTranscriptionProgress[track.id] = progress
                        }
                    }
                )
                try await lyricsStore.save(document, cacheKey: cacheKey)
                self.lyricsDocumentsByTrackID[track.id] = document
                self.updateLyricsMetadata(
                    trackID: track.id,
                    metadata: LyricsMetadata(
                        cacheKey: cacheKey,
                        status: .ready,
                        generatedAt: document.generatedAt,
                        modelName: document.modelName
                    )
                )
                await self.persistLibrary()
                self.statusMessage = "Generated lyrics for \(track.title)."
            } catch is CancellationError {
                if self.activeLyricsTrackID == track.id, case .downloading = self.lyricsModelState { self.lyricsModelState = .notDownloaded }
                self.statusMessage = "Stopped lyrics generation for \(track.title)."
            } catch {
                if self.activeLyricsTrackID == track.id, case .downloading = self.lyricsModelState {
                    self.lyricsModelState = .failed(error.localizedDescription)
                }
                self.updateLyricsMetadata(
                    trackID: track.id,
                    metadata: LyricsMetadata(
                        cacheKey: cacheKey,
                        status: .failed,
                        generatedAt: nil,
                        modelName: "Systran/faster-whisper-small",
                        errorDescription: error.localizedDescription
                    )
                )
                await self.persistLibrary()
                self.statusMessage = "Could not generate lyrics: \(error.localizedDescription)"
            }
        }
    }

    func cancelLyricsGeneration(for track: Track) {
        lyricsGenerationTasks[track.id]?.cancel()
        lyricsQueue.cancel(track.id)
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
            libraryNeedsRecovery = false
            libraryRecoveryMessage = await store.recoveryNotice
            didLoadLibrary = true
            #if os(macOS)
            hydrateTemporaryOnlineTracks(from: loadedLibrary.queue)
            #endif
            lastSavedPlaybackResumeSnapshot = PlaybackResumeSnapshot(
                queue: loadedLibrary.queue,
                resumeState: loadedLibrary.playbackResumeState
            )
            restorePlaybackIfNeeded(from: loadedLibrary)
            #if os(macOS)
            cleanupTemporaryOnlineTracks(keeping: player.state.queue)
            #endif
            startPlaybackAnalysis()
            startPendingLibraryLyricsGenerationIfNeeded()
        } catch {
            didLoadLibrary = false
            libraryNeedsRecovery = true
            libraryRecoveryMessage = "Your library could not be read. Saving is paused to protect the original. Restore the library file, then retry."
            statusMessage = "Could not load library: \(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) {
        guard didLoadLibrary, !libraryNeedsRecovery else { return }
        guard !urls.isEmpty else { return }

        Task {
            isImporting = true
            defer { isImporting = false }

            let result = await importService.importFiles(at: urls)
            library.restoreImports(for: result.tracks)
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
        guard didLoadLibrary, !libraryNeedsRecovery else { return }
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
                        library.restoreImports(for: result.tracks)
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
                library.restoreImports(for: result.tracks)
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
        guard didLoadLibrary, !libraryNeedsRecovery else { return }
        Task {
            isImporting = true
            defer { isImporting = false }

            do {
                let (folderSource, result) = try await importService.importFolder(at: url)
                library.upsertFolderSource(folderSource)
                library.restoreImports(for: result.tracks)
                library.upsertTracks(result.tracks)
                await persistLibrary()
                startPlaybackAnalysis()
                statusMessage = "Imported \(result.tracks.count) track\(result.tracks.count == 1 ? "" : "s") from \(url.lastPathComponent)."
            } catch {
                statusMessage = "Could not import folder: \(error.localizedDescription)"
            }
        }
    }

    func refreshOpenedFolders(force: Bool = false) {
        guard didLoadLibrary, !libraryNeedsRecovery, !library.folderSources.isEmpty else { return }
        guard folderRefreshTask == nil else {
            folderRefreshPending = folderRefreshPending || force
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.folderRefreshTask = nil
                if self.folderRefreshPending {
                    self.folderRefreshPending = false
                    self.refreshOpenedFolders(force: true)
                }
            }

            var importedCount = 0
            var didUpdateTracks = false
            var didRefreshSources = false
            for folderSource in self.library.folderSources {
                guard !Task.isCancelled else { return }
                let folderURL = self.folderURL(for: folderSource)
                guard FileManager.default.fileExists(atPath: folderURL.path) else { continue }

                if !force, let lastScannedDate = folderSource.lastScannedDate {
                    let hasRelevantChanges = await Task.detached(priority: .utility) {
                        Self.watchedFolderHasRelevantChanges(
                            at: folderURL,
                            since: lastScannedDate,
                            recursive: folderSource.isRecursive
                        )
                    }.value
                    guard hasRelevantChanges else { continue }
                }

                do {
                    let (updatedSource, result) = try await self.importService.importFolder(
                        at: folderURL,
                        recursive: folderSource.isRecursive
                    )
                    var sourceToStore = updatedSource
                    sourceToStore.id = folderSource.id
                    self.library.upsertFolderSource(sourceToStore)
                    didRefreshSources = true
                    let previousAlbumFingerprints = self.albumFingerprints(for: self.library.tracks)
                    let previousArtworkFingerprints = self.artworkFingerprints(for: self.library.tracks)
                    let previousTrackCount = self.library.tracks.count
                    self.library.upsertTracks(self.library.excludingRemovedImports(from: result.tracks))
                    if self.albumFingerprints(for: self.library.tracks) != previousAlbumFingerprints {
                        didUpdateTracks = true
                    }
                    if self.artworkFingerprints(for: self.library.tracks) != previousArtworkFingerprints {
                        didUpdateTracks = true
                    }
                    importedCount += max(self.library.tracks.count - previousTrackCount, 0)
                } catch {
                    self.statusMessage = "Could not refresh \(folderURL.lastPathComponent): \(error.localizedDescription)"
                }
            }

            do {
                let previousAvailability = Dictionary(
                    uniqueKeysWithValues: self.library.tracks.map { ($0.id, $0.availability) }
                )
                self.library.markMissingTracks()
                if self.library.tracks.contains(where: { previousAvailability[$0.id] != $0.availability }) {
                    didUpdateTracks = true
                }
            }

            if importedCount > 0 {
                self.statusMessage = "Added \(importedCount) new track\(importedCount == 1 ? "" : "s") from watched folders."
                await self.persistLibrary()
                self.startPlaybackAnalysis()
            } else if didUpdateTracks {
                self.statusMessage = "Updated watched folders."
                await self.persistLibrary()
            } else if didRefreshSources {
                await self.persistLibrary()
            }
        }
        folderRefreshTask = task
    }

    func play(_ track: Track) {
        play(track, within: sortedTracks, preloadLookaheadCount: 1)
    }

    func play(_ track: Track, within tracks: [Track], preloadLookaheadCount: Int = 1) {
        play(
            track,
            within: tracks,
            preloadLookaheadCount: preloadLookaheadCount,
            preservingOnlineQueueGeneration: nil
        )
    }

    private func play(
        _ track: Track,
        within tracks: [Track],
        preloadLookaheadCount: Int = 1,
        preservingOnlineQueueGeneration generation: UUID?
    ) {
        guard !tracks.isEmpty else { return }

        #if os(macOS)
        if generation == nil || onlineQueueGeneration != generation {
            invalidateOnlineQueueGeneration()
        }
        #endif

        let index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        let requestID = UUID()

        playbackRequestID = requestID
        optimisticPlaybackTrackID = track.id

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

    func playAlbum(_ album: LibraryAlbumGroup) {
        guard let firstTrack = album.tracks.first else { return }
        play(firstTrack, within: album.tracks, preloadLookaheadCount: album.tracks.count)
    }

    func playPlaylist(_ playlist: Playlist) {
        let tracks = tracks(for: playlist)
        guard let firstTrack = tracks.first else { return }
        play(firstTrack, within: tracks)
    }

    #if os(macOS)
    func isImporting(_ playlist: RemoteMusicPlaylist) -> Bool {
        importingRemotePlaylistIDs.contains(remotePlaylistImportKey(playlist))
    }

    func hasImported(_ playlist: RemoteMusicPlaylist) -> Bool {
        library.playlists.contains {
            $0.importSource?.service == playlist.service && $0.importSource?.externalID == playlist.id
        }
    }

    func importRemotePlaylist(_ remotePlaylist: RemoteMusicPlaylist) {
        let importKey = remotePlaylistImportKey(remotePlaylist)
        guard importingRemotePlaylistIDs.insert(importKey).inserted else { return }

        Task {
            defer { importingRemotePlaylistIDs.remove(importKey) }
            do {
                let remoteTracks = try await musicServiceConnections.tracks(for: remotePlaylist)
                let importedItems = PlaylistTrackMatcher.match(remoteTracks, in: library.tracks)
                let importedPlaylist = library.upsertImportedPlaylist(
                    name: remotePlaylist.name,
                    source: PlaylistImportSource(
                        service: remotePlaylist.service,
                        externalID: remotePlaylist.id,
                        sourceURL: remotePlaylist.sourceURL
                    ),
                    importedItems: importedItems
                )
                await persistLibrary()

                let matchedCount = importedItems.lazy.filter { $0.matchedTrackID != nil }.count
                let unmatchedCount = importedItems.count - matchedCount
                if unmatchedCount == 0 {
                    statusMessage = "Imported \(importedPlaylist.name) with \(matchedCount) playable track\(matchedCount == 1 ? "" : "s")."
                } else {
                    statusMessage = "Imported \(importedPlaylist.name). \(matchedCount) matched your library; \(unmatchedCount) remain linked to \(remotePlaylist.service.displayName)."
                }
            } catch {
                statusMessage = "Could not import \(remotePlaylist.name): \(error.localizedDescription)"
            }
        }
    }

    private func remotePlaylistImportKey(_ playlist: RemoteMusicPlaylist) -> String {
        "\(playlist.service.rawValue):\(playlist.id)"
    }
    #endif

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

    private func removeTrackIDsFromLiveQueue(_ trackIDs: Set<Track.ID>) {
        guard !trackIDs.isEmpty else { return }
        let currentItemID = player.state.currentItem?.id
        let itemIDs = player.state.queue.items
            .filter { item in
                guard let trackID = item.trackID else { return false }
                return trackIDs.contains(trackID)
            }
            .map(\.id)

        for itemID in itemIDs where itemID != currentItemID {
            player.removeFromQueue(id: itemID)
        }
        if let currentItemID, itemIDs.contains(currentItemID) {
            player.removeFromQueue(id: currentItemID)
        }
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
        guard NightwingEnvironment.defaults.bool(forKey: "nightwing.restorePlaybackOnLaunch"),
              let resumeState = loadedLibrary.playbackResumeState,
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
                autoplay: false
            )
        } catch {
            statusMessage = "Could not restore playback: \(error.localizedDescription)"
        }
    }

    private func playbackStateDidChange(_ state: PlaybackState) {
        let previousState = lastObservedPlaybackState
        lastObservedPlaybackState = state

        guard !isRestoringPlayback else { return }

        #if os(macOS)
        promoteTemporaryTrackIfCompleted(previousState: previousState, currentState: state)
        cleanupTemporaryOnlineTracks(keeping: state.queue)
        #endif

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

    #if os(macOS)
    private func promoteTemporaryTrackIfCompleted(
        previousState: PlaybackState?,
        currentState: PlaybackState
    ) {
        guard let previousState,
              let previousItem = previousState.currentItem,
              let trackID = previousItem.trackID,
              let temporary = temporaryOnlineTracksByID[trackID],
              previousState.duration > 0,
              previousState.currentTime >= previousState.duration - 1 else {
            return
        }

        let movedToAnotherItem = currentState.currentItem?.id != previousItem.id
        let restartedSameItem = currentState.currentItem?.id == previousItem.id &&
            currentState.currentTime < previousState.currentTime - 1
        guard movedToAnotherItem || restartedSameItem else { return }

        var promotedTrack = temporary.track
        promotedTrack.lastPlayedDate = Date()
        promotedTrack.playCount = max(promotedTrack.playCount, 1)
        library.upsertTracks([promotedTrack])
        temporaryOnlineTracksByID.removeValue(forKey: trackID)
        scheduleOnlineArtworkFinalization(for: promotedTrack.id, source: temporary.source)
        schedulePostImportLibraryMaintenance(analyze: false)
        statusMessage = "Added (promotedTrack.title) to Downloaded Tracks."
    }

    private func cleanupTemporaryOnlineTracks(keeping queue: PlaybackQueue) {
        let neededItems: ArraySlice<PlaybackQueueItem>
        if let currentIndex = queue.currentIndex, queue.items.indices.contains(currentIndex) {
            neededItems = queue.items[currentIndex...]
        } else {
            neededItems = queue.items[...]
        }
        let neededTrackIDs = Set(neededItems.compactMap(\.trackID))
        let staleTracks = temporaryOnlineTracksByID.filter { !neededTrackIDs.contains($0.key) }
        guard !staleTracks.isEmpty else { return }

        let staleTrackIDs = Set(staleTracks.keys)
        let staleQueueItemIDs = queue.items.compactMap { item -> PlaybackQueueItem.ID? in
            guard let trackID = item.trackID, staleTrackIDs.contains(trackID) else { return nil }
            return item.id
        }
        for trackID in staleTracks.keys {
            temporaryOnlineTracksByID.removeValue(forKey: trackID)
        }
        for itemID in staleQueueItemIDs where itemID != queue.currentItem?.id {
            player.removeFromQueue(id: itemID)
        }

        let protectedPaths = Set(library.tracks.map { $0.fileURL.standardizedFileURL.path })
            .union(temporaryOnlineTracksByID.values.map { $0.track.fileURL.standardizedFileURL.path })
        let tracksToDelete = staleTracks.values.filter {
            !protectedPaths.contains($0.track.fileURL.standardizedFileURL.path)
        }

        var deletedFileURLs: [URL] = []
        for temporary in tracksToDelete {
            let fileURL = temporary.track.fileURL.standardizedFileURL
            let directoryURL = fileURL.deletingLastPathComponent()
            guard isInsideOnlineDownloads(directoryURL),
                  directoryURL.path.contains("/Nightwing/Online Downloads/Tracks/") else {
                continue
            }

            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try? FileManager.default.removeItem(at: directoryURL)
            }
            setOnlineDownloadState(for: temporary.source.id, state: .idle)
            deletedFileURLs.append(fileURL)
        }

        Task { [onlineSearchService] in
            for fileURL in deletedFileURLs {
                _ = try? await onlineSearchService.removeCachedEntry(localFileURL: fileURL)
            }
        }
    }

    private func hydrateTemporaryOnlineTracks(from queue: PlaybackQueue) {
        guard let cachedEntries = try? OnlineTrackStore().loadCachedTracks() else { return }
        var cachedByPath: [String: CachedTrackEntry] = [:]
        for entry in cachedEntries {
            cachedByPath[URL(fileURLWithPath: entry.localFileURL).standardizedFileURL.path] = entry
        }
        let libraryPaths = Set(library.tracks.map { $0.fileURL.standardizedFileURL.path })

        for item in queue.items {
            guard let trackID = item.trackID,
                  !libraryPaths.contains(item.url.standardizedFileURL.path),
                  let cached = cachedByPath[item.url.standardizedFileURL.path],
                  let sourceURL = URL(string: cached.sourceURL) else {
                continue
            }

            let source = OnlineSearchResult(
                id: cached.id,
                title: cached.title,
                artist: cached.artist,
                duration: cached.duration,
                sourceURL: sourceURL,
                thumbnailURL: cached.thumbnailURL.flatMap(URL.init(string:))
            )
            guard var track = onlineTrack(from: item.url, fallback: source) else { continue }
            track.id = trackID
            temporaryOnlineTracksByID[trackID] = (track, source)
        }
    }
    #endif

    private func updateLyricsMetadata(trackID: Track.ID, metadata: LyricsMetadata) {
        guard let index = library.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        library.tracks[index].lyricsMetadata = metadata
    }

    private func lyricsCacheKey(for track: Track, sourceURL: URL) -> String {
        let stablePath = sourceURL.standardizedFileURL.path
        return "\(track.id.uuidString)-\(Self.fnv1a64Hex(stablePath))"
    }

    private static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
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

    nonisolated private static func watchedFolderHasRelevantChanges(
        at folderURL: URL,
        since lastScannedDate: Date,
        recursive: Bool
    ) -> Bool {
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        if let rootValues = try? folderURL.resourceValues(forKeys: Set(resourceKeys)),
           rootValues.contentModificationDate.map({ $0 > lastScannedDate }) == true {
            return true
        }
        let options: FileManager.DirectoryEnumerationOptions = recursive
            ? [.skipsHiddenFiles]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else {
            return true
        }

        for case let candidateURL as URL in enumerator {
            guard let values = try? candidateURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isDirectory == true || values.isRegularFile == true else {
                return true
            }

            if values.isDirectory == true,
               values.contentModificationDate.map({ $0 > lastScannedDate }) == true {
                return true
            }

            guard AudioFileType.isSupported(candidateURL) || isWatchedFolderArtwork(candidateURL) else {
                continue
            }

            if values.contentModificationDate.map({ $0 > lastScannedDate }) == true ||
                values.creationDate.map({ $0 > lastScannedDate }) == true {
                return true
            }
        }

        return false
    }

    nonisolated private static func isWatchedFolderArtwork(_ fileURL: URL) -> Bool {
        guard ["jpg", "jpeg", "png", "webp", "tif", "tiff"].contains(fileURL.pathExtension.lowercased()) else {
            return false
        }
        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        return ["cover", "folder", "front", "album", "artwork"].contains(name) ||
            name.contains("cover") ||
            name.contains("front") ||
            name.contains("folder") ||
            name.contains("sleeve") ||
            name.contains("artwork")
    }

    private func updateFolderMonitor() {
        folderMonitor = WatchedFolderMonitor(urls: library.folderSources.map { folderURL(for: $0) }) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.folderEventTask?.cancel()
                self.folderEventTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                    self?.refreshOpenedFolders(force: true)
                }
            }
        }
    }

    private func startFolderRefreshTimer() {
        folderRefreshTimer?.invalidate()
        folderRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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

    func dismissLibraryRecoveryNotice() {
        guard !libraryNeedsRecovery else { return }
        libraryRecoveryMessage = nil
    }

    private func persistLibrary() async {
        guard didLoadLibrary, !libraryNeedsRecovery, let store else { return }
        do {
            try await store.save(library)
        } catch JSONLocalLibraryStore.StoreError.recoveryRequired {
            libraryNeedsRecovery = true
            libraryRecoveryMessage = "Your library file became unreadable. Saving is paused to protect it. Restore the file, then retry."
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

