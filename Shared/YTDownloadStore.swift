#if canImport(CommonCrypto)
import CommonCrypto
#endif
import Foundation

/// Persistent cache of downloaded online tracks, keyed by source URL hash.
/// Survives app restarts; stores enough metadata to re-hydrate a track without re-downloading.
final class OnlineTrackStore: Sendable {
    /// Returns the URL where the store's JSON file lives in Application Support.
    static func storeURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Nightwing").appendingPathComponent("OnlineTrackStore.json")
    }
    
    /// Returns the base directory where downloaded audio files are stored.
    static func downloadsBaseURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Nightwing").appendingPathComponent("Downloads")
    }
    
    /// Hash of a URL to use as deduplication key.
    static func hashKey(for url: URL) -> String {
        url.md5()
    }
    
    /// Load cached tracks from disk.
    func loadCachedTracks() throws -> [CachedTrackEntry] {
        let url = Self.storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        if let result = try? decoder.decode([CachedTrackEntry].self, from: data) {
            return result
        }
        
        // Fallback to wrapping in an array (in case the root was a single entry)
        if let result = try? decoder.decode(CachedTrackEntry.self, from: data) {
            return [result]
        }
        
        return []
    }
    
    /// Save all cached tracks to disk.
    func save(_ entries: [CachedTrackEntry]) throws {
        let url = Self.storeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
    }
    
    /// Upsert a single entry.
    func upsert(_ entry: CachedTrackEntry) throws {
        var entries = try loadCachedTracks()
        if let idx = entries.firstIndex(where: { $0.sourceHash == entry.sourceHash }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        try save(entries)
    }
    
    /// Remove an entry by source hash.
    func remove(sourceHash: String) throws {
        var entries = try loadCachedTracks()
        entries.removeAll { $0.sourceHash == sourceHash }
        try save(entries)
    }

    func remove(localFileURL: URL) throws -> CachedTrackEntry? {
        var entries = try loadCachedTracks()
        let standardizedPath = localFileURL.standardizedFileURL.path
        guard let index = entries.firstIndex(where: {
            URL(fileURLWithPath: $0.localFileURL).standardizedFileURL.path == standardizedPath
        }) else {
            return nil
        }

        let removed = entries.remove(at: index)
        try save(entries)
        return removed
    }
}

/// A single downloaded online track's cached metadata.
struct CachedTrackEntry: Codable, Sendable {
    let id: String                    // YouTube video ID
    let title: String
    let artist: String?
    let duration: TimeInterval?
    let sourceURL: String             // original URL as string
    let sourceHash: String            // md5(sourceURL) for dedup
    let localFileURL: String          // path to downloaded audio file
    let thumbnailURL: String?         // thumbnail URL if available
    let cachedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, title, artist, duration, sourceURL, sourceHash, localFileURL, thumbnailURL, cachedAt
    }
}

// MARK: - MD5 extension on URL
extension URL {
    /// Simple MD5 hash of the absolute URL string (ASCII hex).
    func md5() -> String {
        let input = Data(absoluteString.utf8)
        return Data.sha256(of: input).prefix(16).hexEncodedString()
    }
}

private extension Data {
    static func sha256(of input: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        input.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(input.count), &hash)
        }
        return Data(hash)
    }
    
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array where Element == UInt8 {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
