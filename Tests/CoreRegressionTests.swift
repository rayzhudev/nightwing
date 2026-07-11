#if canImport(XCTest) && canImport(Nightwing_macOS)
import XCTest
@testable import Nightwing_macOS

final class CoreRegressionTests: XCTestCase {
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
