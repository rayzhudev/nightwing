import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
private typealias NightwingPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias NightwingPlatformImage = UIImage
#endif

@MainActor
final class NightwingAppModel: ObservableObject {
    private static let playbackAnalysisThrottleNanoseconds: UInt64 = 120_000_000
    private static let playbackAnalysisSaveBatchSize = 12

    @Published private(set) var library: LocalLibrary = .empty
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
    #endif
    private let store: JSONLocalLibraryStore?
    private var folderRefreshTimer: Timer?
    private var playbackAnalysisTask: Task<Void, Never>?
    private var playbackRequestID = UUID()

    init() {
        store = try? JSONLocalLibraryStore.defaultStore()
        Task {
            await loadLibrary()
            refreshOpenedFolders()
        }
        startFolderRefreshTimer()
    }

    deinit {
        folderRefreshTimer?.invalidate()
        playbackAnalysisTask?.cancel()
        #if os(macOS)
        onlineSearchTask?.cancel()
        #endif
    }

    var sortedTracks: [Track] {
        library.tracks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var isPlaybackStarting: Bool {
        optimisticPlaybackTrackID != nil
    }

    var albumGroups: [LibraryAlbumGroup] {
        Dictionary(grouping: library.tracks, by: Self.albumKey(for:))
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
    }

    var recentlyAddedTracks: [Track] {
        library.tracks
            .sorted { $0.dateAdded > $1.dateAdded }
            .prefix(12)
            .map { $0 }
    }

    var onlineDownloadedTracks: [Track] {
        library.tracks
            .filter { $0.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/") }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    func isOnlineDownloadedTrack(_ track: Track) -> Bool {
        track.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/")
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
            .contains { $0.contains(trimmedQuery.lowercased()) }
        }
    }

    func filteredAlbumGroups(matching query: String) -> [LibraryAlbumGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return albumGroups }

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
                .contains { $0.contains(trimmedQuery.lowercased()) }
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
                onlineAlbumResults = albums
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
                updateOnlineDownloadState(for: result.id, state: .idle)
                return
            }
            await deleteOnlineDownloadedFile(URL(fileURLWithPath: cached.localFileURL))
            updateOnlineDownloadState(for: result.id, state: .idle)
        }
    }

    func deleteOnlineDownloadedTrack(_ track: Track) {
        guard isOnlineDownloadedTrack(track) else { return }
        Task { @MainActor [weak self] in
            await self?.deleteOnlineDownloadedFile(track.fileURL)
        }
    }

    func downloadOnlineAlbum(_ album: OnlineAlbumSearchResult) {
        guard let index = onlineAlbumResults.firstIndex(where: { $0.id == album.id }) else { return }
        onlineAlbumResults[index].downloadState = .downloading(progress: 0)
        let albumID = album.id

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let albumFolderURL = try await onlineSearchService.downloadAlbum(album) { progress in
                    Task { @MainActor [weak self] in
                        self?.updateOnlineAlbumDownloadState(for: albumID, state: .downloading(progress: progress))
                    }
                }

                updateOnlineAlbumDownloadState(for: albumID, state: .completed(fileURL: albumFolderURL))
                await importDownloadedOnlineAlbum(albumFolderURL, fallback: album)
            } catch {
                updateOnlineAlbumDownloadState(for: albumID, state: .failed(error.localizedDescription))
                statusMessage = "Album download failed: \(error.localizedDescription)"
            }
        }
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
        guard let index = onlineSearchResults.firstIndex(where: { $0.id == result.id }) else { return }
        let sourceID = result.id
        let action: ((Track) -> Void)? = (autoplay || completion != nil) ? { [weak self] track in
            if autoplay {
                self?.play(track)
            }
            completion?(track)
        } : nil

        if case let .completed(fileURL) = onlineSearchResults[index].downloadState {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let track = await importDownloadedOnlineTrack(fileURL, fallback: result) {
                    action?(track)
                }
            }
            return
        }

        if case .downloading = onlineSearchResults[index].downloadState {
            if let action {
                appendPendingOnlineTrackAction(action, for: sourceID)
            }
            return
        }

        if let action {
            appendPendingOnlineTrackAction(action, for: sourceID)
        }

        onlineSearchResults[index].downloadState = .downloading(progress: 0)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let fileURL = try await onlineSearchService.download(result) { progress in
                    Task { @MainActor [weak self] in
                        self?.updateOnlineDownloadState(for: sourceID, state: .downloading(progress: progress))
                    }
                }

                updateOnlineDownloadState(for: sourceID, state: .completed(fileURL: fileURL))
                if let track = await importDownloadedOnlineTrack(fileURL, fallback: result) {
                    runPendingOnlineTrackActions(for: sourceID, track: track)
                }
            } catch {
                pendingOnlineTrackActions[sourceID] = nil
                updateOnlineDownloadState(for: sourceID, state: .failed(error.localizedDescription))
                statusMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    private func runPendingOnlineTrackActions(for id: OnlineSearchResult.ID, track: Track) {
        let actions = pendingOnlineTrackActions.removeValue(forKey: id) ?? []
        for action in actions {
            action(track)
        }
    }

    private func appendPendingOnlineTrackAction(_ action: @escaping (Track) -> Void, for id: OnlineSearchResult.ID) {
        guard pendingOnlineTrackActions[id]?.isEmpty != false else { return }
        pendingOnlineTrackActions[id, default: []].append(action)
    }

    private func updateOnlineDownloadState(for id: OnlineSearchResult.ID, state: OnlineSearchResult.DownloadState) {
        guard let index = onlineSearchResults.firstIndex(where: { $0.id == id }) else { return }
        onlineSearchResults[index].downloadState = state
    }

    private func updateOnlineAlbumDownloadState(for id: OnlineAlbumSearchResult.ID, state: OnlineSearchResult.DownloadState) {
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
            for resultIndex in onlineSearchResults.indices {
                if case let .completed(completedURL) = onlineSearchResults[resultIndex].downloadState,
                   completedURL.standardizedFileURL.path == standardizedURL.path {
                    onlineSearchResults[resultIndex].downloadState = .idle
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

    private func resultsWithCacheState(_ results: [OnlineSearchResult]) async -> [OnlineSearchResult] {
        var updatedResults = results
        let cachedEntries = (try? await onlineSearchService.getAllCachedEntries()) ?? []
        var entriesByHash: [String: CachedTrackEntry] = [:]
        for entry in cachedEntries {
            entriesByHash[entry.sourceHash] = entry
        }

        for index in updatedResults.indices {
            let hash = OnlineTrackStore.hashKey(for: updatedResults[index].sourceURL)
            guard let cached = entriesByHash[hash] else { continue }
            let fileURL = URL(fileURLWithPath: cached.localFileURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            updatedResults[index].downloadState = .completed(fileURL: fileURL)
        }
        return updatedResults
    }

    private func importDownloadedOnlineTrack(_ fileURL: URL, fallback result: OnlineSearchResult) async -> Track? {
        if let existingTrack = library.tracks.first(where: { $0.fileURL.standardizedFileURL.path == fileURL.standardizedFileURL.path }) {
            return existingTrack
        }

        let importResult = await importService.importFiles(at: [fileURL], albumOverride: "Online Downloads")
        var importedTracks = importResult.tracks
        if importedTracks.indices.contains(0) {
            if importedTracks[0].title == fileURL.deletingPathExtension().lastPathComponent {
                importedTracks[0].title = result.title
            }
            if importedTracks[0].artist == nil {
                importedTracks[0].artist = result.artist
            }
            if importedTracks[0].duration == nil {
                importedTracks[0].duration = result.duration
            }
        }

        library.upsertTracks(importedTracks)
        schedulePostImportLibraryMaintenance()

        if let track = importedTracks.first {
            statusMessage = "Downloaded \(track.title)."
            return track
        } else if let failure = importResult.failures.first {
            statusMessage = "Downloaded but could not import: \(failure.errorDescription)"
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

    private func schedulePostImportLibraryMaintenance() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistLibrary()
            self.startPlaybackAnalysis()
        }
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
        playlist.items.compactMap { item in
            guard let track = library.tracks.first(where: { $0.id == item.trackID }) else { return nil }
            return PlaylistTrackEntry(item: item, track: track)
        }
    }

    func track(for item: PlaybackQueueItem?) -> Track? {
        guard let item else { return nil }
        let itemPath = item.url.standardizedFileURL.path
        return library.tracks.first { track in
            track.fileURL.standardizedFileURL.path == itemPath
        }
    }

    func currentDisplayTrack() -> Track? {
        if let optimisticPlaybackTrackID,
           let track = library.tracks.first(where: { $0.id == optimisticPlaybackTrackID }) {
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
        library.movePlaylistItem(id: itemID, inPlaylist: playlist.id, to: index)
        Task {
            await persistLibrary()
        }
    }

    func enqueue(_ track: Track) {
        player.enqueue(
            url: playbackURL(for: track),
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
}

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
    static let background = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let sidebar = Color.black
    static let panel = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
    static let panelElevated = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let rowHover = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.10)
    static let glassTint = Color.white.opacity(0.075)
    static let glassElevatedTint = Color.white.opacity(0.13)
    static let glassPressedTint = Color.white.opacity(0.18)
    static let glassStroke = Color.white.opacity(0.18)
    static let glassInnerStroke = Color.white.opacity(0.07)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 179 / 255, green: 179 / 255, blue: 179 / 255)
    static let action = Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)
    static let warning = Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255)

    static var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 33 / 255, green: 33 / 255, blue: 33 / 255),
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

            PlaybackSpeedMenu()
        }
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
                RepeatButton()

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
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                trackSummary

                Spacer(minLength: 8)

                ShuffleButton(isCompact: true)
                RepeatButton(isCompact: true)

                Button {
                    appModel.togglePlayback()
                } label: {
                    Image(systemName: showsPauseState ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(NightwingTheme.primaryText)
                .accessibilityLabel(showsPauseState ? "Pause" : "Play")

                Button {
                    try? player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(NightwingTheme.primaryText)
                .accessibilityLabel("Next")

                PlaybackSpeedMenu(isCompact: true)
            }

            Slider(value: progressBinding, in: 0...max(player.state.duration, 1))
                .disabled(player.state.currentItem == nil)
                .accessibilityLabel("Playback position")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(NightwingTheme.sidebar)
    }
}

struct PlaybackSpeedMenu: View {
    @EnvironmentObject private var player: PlayerEngine

    var isCompact = false

    var body: some View {
        Menu {
            Section("Playback Speed") {
                ForEach(PlaybackProfile.speedPresets) { preset in
                    Button {
                        player.setSpeedPreset(preset)
                    } label: {
                        if isSelected(preset) {
                            Label(menuTitle(for: preset), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(for: preset))
                        }
                    }
                }
            }

            Text("Presets use whole semitone shifts so pitch stays cleaner than arbitrary speeds.")
        } label: {
            HStack(spacing: 4) {
                Text(PlaybackProfile.speedLabel(for: player.state.profile.clampedSpeed))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .lineLimit(1)

                if !isCompact {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(NightwingTheme.primaryText)
            .padding(.horizontal, isCompact ? 8 : 10)
            .frame(height: isCompact ? 28 : 30)
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
    }

    private func isSelected(_ preset: PlaybackSpeedPreset) -> Bool {
        abs(player.state.profile.clampedSpeed - preset.speed) <= 0.006
    }

    private func menuTitle(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "\(preset.title) - \(preset.subtitle)"
        }

        return "\(preset.title) - \(preset.subtitle)"
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

                PlaybackSpeedMenu()
            }
            .buttonStyle(.plain)

            VolumeControlView()
                .frame(maxWidth: 320)
        }
    }
}

struct NightcoreControlPanel: View {
    @EnvironmentObject private var player: PlayerEngine

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
            HStack {
                Label("Nightcore", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Toggle("Nightcore", isOn: nightcoreEnabled)
                    .labelsHidden()
            }

            Picker("Speed", selection: speed) {
                ForEach(PlaybackProfile.speedPresets) { preset in
                    Text(preset.title).tag(preset.speed)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Custom speed") {
                Text("\(player.state.profile.clampedSpeed, specifier: "%.3f")x")
                    .monospacedDigit()
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
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
