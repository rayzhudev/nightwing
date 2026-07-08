import AVFoundation
import Foundation

public struct LibraryImportService {
    public enum ImportError: Error, Equatable, Sendable {
        case unsupportedFileType(URL)
        case notAFolder(URL)
        case folderEnumerationFailed(URL)
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func importFile(at fileURL: URL, albumOverride: String? = nil) async throws -> Track {
        guard let fileType = AudioFileType(fileExtension: fileURL.pathExtension) else {
            throw ImportError.unsupportedFileType(fileURL)
        }

        let asset = AVURLAsset(url: fileURL)
        let metadata = await MetadataReader.metadata(from: asset)
        let fallbackTitle = fileURL.deletingPathExtension().lastPathComponent
        let bookmarkData = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let artworkURL = Self.sidecarArtworkURL(for: fileURL, fileManager: fileManager)
        let artworkBookmarkData = artworkURL.flatMap {
            try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        let track = Track(
            fileURL: fileURL,
            bookmarkData: bookmarkData,
            title: title?.isEmpty == false ? title! : fallbackTitle,
            artist: metadata.artist,
            album: metadata.album ?? normalizedAlbumName(albumOverride),
            albumArtist: metadata.albumArtist,
            genre: metadata.genre,
            releaseYear: metadata.releaseYear,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            artworkCacheKey: artworkURL != nil || metadata.hasArtwork ? Self.artworkCacheKey(for: fileURL) : nil,
            artworkURL: artworkURL,
            artworkBookmarkData: artworkBookmarkData,
            fileType: fileType,
            availability: fileManager.fileExists(atPath: fileURL.path) ? .available : .missing
        )

        return track
    }

    private func normalizedAlbumName(_ albumName: String?) -> String? {
        let trimmedName = albumName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName?.isEmpty == false ? trimmedName : nil
    }

    private static func artworkCacheKey(for fileURL: URL) -> String {
        let stablePath = fileURL.standardizedFileURL.path
        return stablePath
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            .map { "\($0)-artwork" } ?? "\(fileURL.lastPathComponent)-artwork"
    }

    private static func sidecarArtworkURL(for fileURL: URL, fileManager: FileManager) -> URL? {
        let folderURL = fileURL.deletingLastPathComponent()

        if let artworkURL = artworkFileURL(in: folderURL, fileManager: fileManager) {
            return artworkURL
        }

        let parentURL = folderURL.deletingLastPathComponent()
        guard parentURL.path != folderURL.path else { return nil }
        return artworkFileURL(in: parentURL, fileManager: fileManager)
    }

    private static func artworkFileURL(in folderURL: URL, fileManager: FileManager) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents
            .filter { isArtworkImageURL($0) }
            .compactMap { fileURL -> (url: URL, score: Int)? in
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return (fileURL, artworkScore(for: fileURL))
            }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }

                return $0.url.standardizedFileURL.path.localizedStandardCompare($1.url.standardizedFileURL.path) == .orderedAscending
            }
            .first?
            .url
    }

    private static func isArtworkImageURL(_ fileURL: URL) -> Bool {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "webp", "tif", "tiff":
            return true
        default:
            return false
        }
    }

    private static func artworkScore(for fileURL: URL) -> Int {
        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()

        switch name {
        case "cover", "folder", "front", "album", "artwork":
            return 100
        default:
            break
        }

        if name.contains("cover") || name.contains("front") {
            return 80
        }

        if name.contains("folder") || name.contains("sleeve") || name.contains("artwork") {
            return 70
        }

        return 0
    }

    public func importFiles(at fileURLs: [URL], albumOverride: String? = nil) async -> LibraryImportResult {
        var tracks: [Track] = []
        var failures: [LibraryImportFailure] = []

        for fileURL in fileURLs {
            do {
                tracks.append(try await importFile(at: fileURL, albumOverride: albumOverride))
            } catch {
                failures.append(LibraryImportFailure(url: fileURL, errorDescription: String(describing: error)))
            }
        }

        return LibraryImportResult(tracks: tracks, failures: failures)
    }

    public func importFolder(at folderURL: URL, recursive: Bool = true) async throws -> (FolderSource, LibraryImportResult) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImportError.notAFolder(folderURL)
        }

        let bookmarkData = try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folderSource = FolderSource(
            folderURL: folderURL,
            bookmarkData: bookmarkData,
            isRecursive: recursive,
            lastScannedDate: Date()
        )

        let result: LibraryImportResult
        if recursive {
            result = try await importFolderAsAlbums(at: folderURL)
        } else {
            let fileURLs = try audioFileURLs(in: folderURL, recursive: false)
            result = await importFiles(at: fileURLs, albumOverride: folderURL.lastPathComponent)
        }

        return (folderSource, result)
    }

    private func importFolderAsAlbums(at folderURL: URL) async throws -> LibraryImportResult {
        var result = LibraryImportResult()
        let albumFolderURLs = try audioAlbumFolderURLs(in: folderURL)

        for albumFolderURL in albumFolderURLs {
            let fileURLs = try directAudioFileURLs(in: albumFolderURL)
            guard !fileURLs.isEmpty else { continue }

            let childResult = await importFiles(at: fileURLs, albumOverride: albumFolderURL.lastPathComponent)
            result.tracks.append(contentsOf: childResult.tracks)
            result.failures.append(contentsOf: childResult.failures)
        }

        return result
    }

    private func audioAlbumFolderURLs(in folderURL: URL) throws -> [URL] {
        var albumFolderURLs: [URL] = []

        if try !directAudioFileURLs(in: folderURL).isEmpty {
            albumFolderURLs.append(folderURL)
        }

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.folderEnumerationFailed(folderURL)
        }

        for case let candidateURL as URL in enumerator {
            let values = try? candidateURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            if try !directAudioFileURLs(in: candidateURL).isEmpty {
                albumFolderURLs.append(candidateURL)
            }
        }

        return albumFolderURLs.sortedByStandardizedPath()
    }

    private func directAudioFileURLs(in folderURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { fileURL in
            guard AudioFileType.isSupported(fileURL) else { return false }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        .sortedByStandardizedPath()
    }

    private func audioFileURLs(in folderURL: URL, recursive: Bool) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw ImportError.folderEnumerationFailed(folderURL)
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            guard AudioFileType.isSupported(fileURL) else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                fileURLs.append(fileURL)
            }
        }
        return fileURLs.sortedByStandardizedPath()
    }
}

private extension Array where Element == URL {
    func sortedByStandardizedPath() -> [URL] {
        sorted {
            $0.standardizedFileURL.path.localizedStandardCompare($1.standardizedFileURL.path) == .orderedAscending
        }
    }
}

public struct LibraryImportResult: Equatable, Sendable {
    public var tracks: [Track]
    public var failures: [LibraryImportFailure]

    public init(tracks: [Track] = [], failures: [LibraryImportFailure] = []) {
        self.tracks = tracks
        self.failures = failures
    }
}

public struct LibraryImportFailure: Equatable, Sendable {
    public var url: URL
    public var errorDescription: String

    public init(url: URL, errorDescription: String) {
        self.url = url
        self.errorDescription = errorDescription
    }
}

private struct AudioMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var releaseYear: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: TimeInterval?
    var hasArtwork: Bool
}

private enum MetadataReader {
    static func metadata(from asset: AVURLAsset) async -> AudioMetadata {
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let formatMetadata = (try? await asset.load(.metadata)) ?? []
        let metadataItems = commonMetadata + formatMetadata
        let duration = try? await asset.load(.duration)
        let durationSeconds = duration.map(CMTimeGetSeconds) ?? 0

        return AudioMetadata(
            title: await stringValue(in: metadataItems, matching: ["title"]),
            artist: await stringValue(in: metadataItems, matching: ["artist"], excluding: ["album"]),
            album: await stringValue(in: metadataItems, matching: ["albumname", "album name", "album"], excluding: ["artist"]),
            albumArtist: await stringValue(in: metadataItems, matching: ["albumartist", "album artist"]),
            genre: await stringValue(in: metadataItems, matching: ["genre"]),
            releaseYear: await releaseYear(in: metadataItems),
            trackNumber: await integerValue(in: metadataItems, matching: ["tracknumber", "track number"]),
            discNumber: await integerValue(in: metadataItems, matching: ["discnumber", "disc number", "disknumber", "disk number"]),
            duration: durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : nil,
            hasArtwork: containsArtwork(in: metadataItems)
        )
    }

    private static func stringValue(
        in metadataItems: [AVMetadataItem],
        matching tokens: [String],
        excluding excludedTokens: [String] = []
    ) async -> String? {
        for item in metadataItems {
            let key = searchableKey(for: item)
            guard tokens.contains(where: { key.contains($0) }) else {
                continue
            }
            guard excludedTokens.allSatisfy({ !key.contains($0) }) else {
                continue
            }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func integerValue(in metadataItems: [AVMetadataItem], matching tokens: [String]) async -> Int? {
        guard let string = await stringValue(in: metadataItems, matching: tokens) else {
            return nil
        }

        let prefix = string.split(separator: "/").first.map(String.init) ?? string
        return Int(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func releaseYear(in metadataItems: [AVMetadataItem]) async -> Int? {
        guard let dateString = await stringValue(
            in: metadataItems,
            matching: ["year", "date", "releasedate", "release date", "originaldate", "original date"]
        ) else {
            return nil
        }

        let match = dateString.firstMatch(of: /(?:19|20)\d{2}/)
        return match.flatMap { Int($0.output) }
    }

    private static func containsArtwork(in metadataItems: [AVMetadataItem]) -> Bool {
        metadataItems.contains { item in
            searchableKey(for: item).contains("artwork") || searchableKey(for: item).contains("cover")
        }
    }

    private static func searchableKey(for item: AVMetadataItem) -> String {
        [
            item.commonKey?.rawValue,
            item.identifier?.rawValue,
            item.keySpace?.rawValue,
            item.key as? String
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }
}
