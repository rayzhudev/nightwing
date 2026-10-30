#if canImport(XCTest) && canImport(Nightwing_macOS)
import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import Nightwing_macOS

final class CoreRegressionTests: XCTestCase {
    func testDefaultAccentMatchesMacOSInsteadOfForcingBlue() throws {
        XCTAssertTrue(NightwingEnvironment.isIsolated)
        let defaults = NightwingEnvironment.defaults
        let previous = defaults.object(forKey: "nightwing.accentColor")
        defer { if let previous { defaults.set(previous, forKey: "nightwing.accentColor") } else { defaults.removeObject(forKey: "nightwing.accentColor") } }
        defaults.removeObject(forKey: "nightwing.accentColor")
        XCTAssertEqual(defaults.string(forKey: "nightwing.accentColor"), NightwingAccent.system.rawValue)
        let actual = try XCTUnwrap(NSColor(NightwingTheme.action).usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
    }

    func testExplicitAccentOverrideIsPreserved() throws {
        XCTAssertTrue(NightwingEnvironment.isIsolated)
        let defaults = NightwingEnvironment.defaults
        let previous = defaults.object(forKey: "nightwing.accentColor")
        defer { if let previous { defaults.set(previous, forKey: "nightwing.accentColor") } else { defaults.removeObject(forKey: "nightwing.accentColor") } }
        for chosen in [NightwingAccent.green, .purple] {
            defaults.set(chosen.rawValue, forKey: "nightwing.accentColor")
            let actual = try XCTUnwrap(NSColor(NightwingTheme.action).usingColorSpace(.sRGB))
            let expected = try XCTUnwrap(NSColor(chosen.color).usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
            XCTAssertEqual(defaults.string(forKey: "nightwing.accentColor"), chosen.rawValue)
        }
    }

    func testAlbumDownloadErrorSurvivesPlaylistCompletionMessage() {
        let output = """
        ERROR: unable to download video data: HTTP Error 403: Forbidden
        [download] Finished downloading playlist: Album - Superache
        """
        XCTAssertEqual(YtDlpDownloadService.diagnosticMessage(from: output),
                       "ERROR: unable to download video data: HTTP Error 403: Forbidden")
    }

    func testDownloadDiagnosticKeepsLastErrorInsteadOfProgressOrWarning() {
        let output = """
        ERROR: first track failed
        ERROR: second track is unavailable
        WARNING: playlist incomplete
        [download] Finished downloading playlist
        """
        XCTAssertEqual(YtDlpDownloadService.diagnosticMessage(from: output),
                       "ERROR: second track is unavailable")
        XCTAssertEqual(YtDlpDownloadService.diagnosticMessage(from: "\n "), "Unknown error")
    }

    func testOAuthRandomValuesAreURLSafeAndUnique() throws {
        let first = try MusicServiceConnections.randomURLSafeString(byteCount: 48)
        let second = try MusicServiceConnections.randomURLSafeString(byteCount: 48)

        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }

    func testOAuthCallbackParametersKeepFirstDuplicateValue() throws {
        let callback = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/callback?state=expected&state=attacker&code=one-time-code"))

        let parameters = MusicServiceConnections.oauthParameters(from: callback)

        XCTAssertEqual(parameters["state"], "expected")
        XCTAssertEqual(parameters["code"], "one-time-code")
    }

    func testPlaybackProgressConvertsRenderFramesToHighResolutionSourceFrames() {
        let startFrame: AVAudioFramePosition = 96 * 88_200
        let playerFrames: AVAudioFramePosition = 90 * 44_100
        let endFrame: AVAudioFramePosition = 260 * 88_200

        let sourceFrame = PlayerEngine.sourceFramePosition(
            scheduledStartFrame: startFrame,
            playerSampleTime: playerFrames,
            playerSampleRate: 44_100,
            sourceSampleRate: 88_200,
            endFrame: endFrame
        )

        XCTAssertEqual(sourceFrame, 186 * 88_200)
    }

    func testPlaybackProgressClampsConvertedFramesAtScheduledEnd() {
        let endFrame: AVAudioFramePosition = 260 * 88_200
        let sourceFrame = PlayerEngine.sourceFramePosition(
            scheduledStartFrame: 250 * 88_200,
            playerSampleTime: 20 * 44_100,
            playerSampleRate: 44_100,
            sourceSampleRate: 88_200,
            endFrame: endFrame
        )

        XCTAssertEqual(sourceFrame, endFrame)
    }

    func testReplacingShuffledQueueKeepsSelectedItemAndShufflesVisibleQueue() {
        let originalItems = makeQueueItems(count: 5, prefix: "original")
        let replacementItems = makeQueueItems(count: 6, prefix: "replacement")
        var queue = PlaybackQueue(items: originalItems, currentIndex: 2)

        queue.setShuffled(true)
        queue.replace(with: replacementItems, startingAt: 4)

        XCTAssertTrue(queue.isShuffled)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentItem?.id, replacementItems[4].id)

        queue.setShuffled(false)
        XCTAssertEqual(queue.items, replacementItems)
        XCTAssertEqual(queue.currentIndex, 4)
    }

    func testBatchUpsertPreservesUserStateAndUpdatesImportedMetadata() {
        let url = URL(fileURLWithPath: "/tmp/nightwing-existing.mp3")
        let existingID = UUID()
        let dateAdded = Date(timeIntervalSince1970: 1_000)
        let lastPlayedDate = Date(timeIntervalSince1970: 2_000)
        let existing = Track(
            id: existingID,
            fileURL: url,
            title: "Old title",
            fileType: .mp3,
            playbackNormalizationGain: 0.75,
            playbackEndTime: 123,
            playbackAnalysisVersion: 1,
            dateAdded: dateAdded,
            lastPlayedDate: lastPlayedDate,
            playCount: 9
        )
        let refreshed = Track(
            fileURL: url,
            title: "Updated title",
            artist: "Updated artist",
            fileType: .mp3
        )
        var library = LocalLibrary(tracks: [existing])

        library.upsertTracks([refreshed])

        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(library.tracks[0].id, existingID)
        XCTAssertEqual(library.tracks[0].title, "Updated title")
        XCTAssertEqual(library.tracks[0].artist, "Updated artist")
        XCTAssertEqual(library.tracks[0].dateAdded, dateAdded)
        XCTAssertEqual(library.tracks[0].lastPlayedDate, lastPlayedDate)
        XCTAssertEqual(library.tracks[0].playCount, 9)
        XCTAssertEqual(library.tracks[0].playbackNormalizationGain, 0.75)
        XCTAssertEqual(library.tracks[0].playbackEndTime, 123)
        XCTAssertEqual(library.tracks[0].playbackAnalysisVersion, 1)
    }

    func testMissingTrackAvailabilityUsesResolvedBookmark() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let availableURL = directory.appendingPathComponent("available.mp3")
        try Data().write(to: availableURL)
        let bookmarkData = try availableURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let stalePath = directory.appendingPathComponent("old-location.mp3")
        var library = LocalLibrary(tracks: [
            Track(
                fileURL: stalePath,
                bookmarkData: bookmarkData,
                title: "Available",
                fileType: .mp3,
                availability: .missing
            )
        ])

        library.markMissingTracks()

        XCTAssertEqual(library.tracks[0].fileURL.standardizedFileURL, availableURL.standardizedFileURL)
        XCTAssertEqual(library.tracks[0].availability, .available)
    }

    func testResolvedBookmarkRemapsPersistedShuffledQueueWithoutLosingQueueState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let availableURL = directory.appendingPathComponent("available.mp3")
        try Data().write(to: availableURL)
        let bookmarkData = try availableURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let staleURL = directory.appendingPathComponent("old-location.mp3")
        let track = Track(
            fileURL: staleURL,
            bookmarkData: bookmarkData,
            title: "Available",
            fileType: .mp3,
            availability: .missing
        )
        let trackQueueItem = PlaybackQueueItem(
            trackID: track.id,
            url: staleURL,
            title: track.title
        )
        let otherQueueItem = PlaybackQueueItem(
            url: directory.appendingPathComponent("other.mp3"),
            title: "Other"
        )
        let unshuffledIDs = [trackQueueItem.id, otherQueueItem.id]
        var queue = PlaybackQueue(items: [trackQueueItem, otherQueueItem], currentIndex: 0)
        queue.setShuffled(true)
        let selectedItemID = try XCTUnwrap(queue.currentItem?.id)
        let persistedLibrary = LocalLibrary(tracks: [track], queue: queue)
        var restoredLibrary = try JSONDecoder().decode(
            LocalLibrary.self,
            from: JSONEncoder().encode(persistedLibrary)
        )

        restoredLibrary.markMissingTracks()

        XCTAssertTrue(restoredLibrary.queue.isShuffled)
        XCTAssertEqual(restoredLibrary.queue.currentItem?.id, selectedItemID)
        XCTAssertEqual(
            restoredLibrary.queue.items.first(where: { $0.id == trackQueueItem.id })?.url.standardizedFileURL,
            availableURL.standardizedFileURL
        )

        restoredLibrary.queue.setShuffled(false)

        XCTAssertEqual(restoredLibrary.queue.items.map(\.id), unshuffledIDs)
        XCTAssertEqual(
            restoredLibrary.queue.items.first(where: { $0.id == trackQueueItem.id })?.url.standardizedFileURL,
            availableURL.standardizedFileURL
        )
    }

    func testDeletingTrackRemovesPersistedQueueAndPlaylistReferences() {
        let removedTrack = Track(
            fileURL: URL(fileURLWithPath: "/tmp/remove-me.mp3"),
            title: "Remove me",
            fileType: .mp3
        )
        let keptTrack = Track(
            fileURL: URL(fileURLWithPath: "/tmp/keep-me.mp3"),
            title: "Keep me",
            fileType: .mp3
        )
        let queueItems = [removedTrack, keptTrack].map {
            PlaybackQueueItem(trackID: $0.id, url: $0.fileURL, title: $0.title)
        }
        var playlist = Playlist(name: "Test")
        playlist.items = [PlaylistItem(trackID: removedTrack.id), PlaylistItem(trackID: keptTrack.id)]
        var library = LocalLibrary(
            tracks: [removedTrack, keptTrack],
            playlists: [playlist],
            queue: PlaybackQueue(items: queueItems, currentIndex: 0)
        )

        library.deleteTrack(id: removedTrack.id)

        XCTAssertEqual(library.tracks.map(\.id), [keptTrack.id])
        XCTAssertEqual(library.queue.items.compactMap(\.trackID), [keptTrack.id])
        XCTAssertEqual(library.playlists[0].items.map(\.trackID), [keptTrack.id])
    }

    func testRemovingImportedTracksKeepsThemExcludedFromWatchedFolderRefresh() {
        let removedTrack = Track(
            fileURL: URL(fileURLWithPath: "/tmp/album/remove-me.mp3"),
            title: "Remove me",
            fileType: .mp3
        )
        let keptTrack = Track(
            fileURL: URL(fileURLWithPath: "/tmp/other/keep-me.mp3"),
            title: "Keep me",
            fileType: .mp3
        )
        var library = LocalLibrary(tracks: [removedTrack, keptTrack])

        library.removeImportedTracks([removedTrack])
        let refreshedTracks = library.excludingRemovedImports(from: [removedTrack, keptTrack])
        library.upsertTracks(refreshedTracks)

        XCTAssertEqual(library.tracks.map(\.id), [keptTrack.id])
    }

    func testManualReimportRestoresPreviouslyRemovedTrack() {
        let track = Track(
            fileURL: URL(fileURLWithPath: "/tmp/album/restore-me.mp3"),
            title: "Restore me",
            fileType: .mp3
        )
        var library = LocalLibrary(tracks: [track])

        library.removeImportedTracks([track])
        library.restoreImports(for: [track])
        library.upsertTracks([track])

        XCTAssertEqual(library.tracks.map(\.id), [track.id])
        XCTAssertTrue(library.excludingRemovedImports(from: [track]).contains(track))
    }

    func testRemovedImportPathsRemainCompatibleWithOlderPersistedLibraries() throws {
        let data = try JSONEncoder().encode(LocalLibrary())

        let library = try JSONDecoder().decode(LocalLibrary.self, from: data)

        XCTAssertNil(library.removedImportedTrackPaths)
    }

    func testImportedPlaylistRefreshUpdatesInPlace() {
        let matchedTrack = Track(
            fileURL: URL(fileURLWithPath: "/tmp/nightwing-import-match.flac"),
            title: "Midnight Flight",
            artist: "Ray",
            fileType: .flac
        )
        var library = LocalLibrary(tracks: [matchedTrack])
        let source = PlaylistImportSource(
            service: .spotify,
            externalID: "spotify-playlist-1",
            sourceURL: URL(string: "https://open.spotify.com/playlist/spotify-playlist-1")
        )

        let original = library.upsertImportedPlaylist(
            name: "First Name",
            source: source,
            importedItems: [
                ImportedPlaylistItem(id: "remote-1", title: "Midnight Flight", matchedTrackID: matchedTrack.id),
                ImportedPlaylistItem(id: "remote-2", title: "Unmatched")
            ]
        )
        let refreshed = library.upsertImportedPlaylist(
            name: "Updated Name",
            source: source,
            importedItems: [
                ImportedPlaylistItem(id: "remote-1", title: "Midnight Flight", matchedTrackID: matchedTrack.id)
            ]
        )

        XCTAssertEqual(library.playlists.count, 1)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.name, "Updated Name")
        XCTAssertEqual(refreshed.displayedItemCount, 1)
        XCTAssertEqual(refreshed.items.map(\.trackID), [matchedTrack.id])
    }

    func testRemoteTrackMatcherHandlesYouTubeVideoLabels() {
        let localTrack = Track(
            fileURL: URL(fileURLWithPath: "/tmp/nightwing-matcher.mp3"),
            title: "Blue Horizon",
            artist: "Nightwing",
            duration: 180,
            fileType: .mp3
        )
        let remoteTrack = RemoteMusicTrack(
            id: "video-1",
            title: "Blue Horizon (Official Music Video)",
            artist: "Nightwing",
            duration: 182
        )

        let result = PlaylistTrackMatcher.match([remoteTrack], in: [localTrack])

        XCTAssertEqual(result.first?.matchedTrackID, localTrack.id)
    }

    func testPlaylistWithoutImportMetadataStillDecodes() throws {
        let playlist = Playlist(name: "Local Playlist")

        let decoded = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist))

        XCTAssertNil(decoded.importSource)
        XCTAssertNil(decoded.importedItems)
        XCTAssertEqual(decoded.displayedItemCount, 0)
    }

    @MainActor
    func testWatchedFolderDetectsNestedFileChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let change = expectation(description: "Recursive filesystem change")
        change.assertForOverFulfill = false
        let monitor = WatchedFolderMonitor(urls: [directory]) { change.fulfill() }
        try Data("new audio".utf8).write(to: nested.appendingPathComponent("song.mp3"))
        await fulfillment(of: [change], timeout: 8)
        withExtendedLifetime(monitor) {}
    }

    private func makeQueueItems(count: Int, prefix: String) -> [PlaybackQueueItem] {
        (0..<count).map { index in
            PlaybackQueueItem(
                url: URL(fileURLWithPath: "/tmp/\(prefix)-\(index).mp3"),
                title: "\(prefix)-\(index)"
            )
        }
    }
}
#endif
