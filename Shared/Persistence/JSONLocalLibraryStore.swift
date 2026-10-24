import Foundation

public actor JSONLocalLibraryStore {
    public enum StoreError: Error, LocalizedError, Sendable {
        case unableToCreateApplicationSupportDirectory
        case recoveryRequired

        public var errorDescription: String? {
            switch self {
            case .unableToCreateApplicationSupportDirectory: return "Could not open the library folder."
            case .recoveryRequired: return "Your library could not be read. Saving is paused to protect it. Restore the library file and retry."
            }
        }
    }

    public let fileURL: URL
    public private(set) var recoveryNotice: String?
    private var savingBlocked = false
    public var backupURL: URL { fileURL.appendingPathExtension("backup") }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultStore(
        applicationName: String = "Nightwing",
        fileManager: FileManager = .default
    ) throws -> JSONLocalLibraryStore {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.unableToCreateApplicationSupportDirectory
        }

        let directoryURL = applicationSupportURL.appendingPathComponent(applicationName, isDirectory: true)
        let libraryURL = directoryURL.appendingPathComponent("LocalLibrary.json")
        return JSONLocalLibraryStore(fileURL: libraryURL, fileManager: fileManager)
    }

    public func load() throws -> LocalLibrary {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            guard !savingBlocked else { throw StoreError.recoveryRequired }
            return .empty
        }

        do {
            let library = try decoder.decode(LocalLibrary.self, from: Data(contentsOf: fileURL))
            savingBlocked = false
            recoveryNotice = nil
            return library
        } catch {
            savingBlocked = true
            guard let data = try? Data(contentsOf: backupURL),
                  let recovered = try? decoder.decode(LocalLibrary.self, from: data) else {
                throw StoreError.recoveryRequired
            }
            // Preserve the original before restoring a validated backup.
            let preservedURL = fileURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
            try fileManager.copyItem(at: fileURL, to: preservedURL)
            try data.write(to: fileURL, options: .atomic)
            savingBlocked = false
            recoveryNotice = "Restored your library from its backup. The unreadable original was preserved as \(preservedURL.lastPathComponent)."
            return recovered
        }
    }

    public func save(_ library: LocalLibrary) throws {
        guard !savingBlocked else { throw StoreError.recoveryRequired }
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(library)
        if fileManager.fileExists(atPath: fileURL.path) {
            // Never replace an unreadable file, even if this store hasn't loaded yet.
            let previous = try Data(contentsOf: fileURL)
            guard (try? decoder.decode(LocalLibrary.self, from: previous)) != nil else {
                savingBlocked = true
                throw StoreError.recoveryRequired
            }
            try previous.write(to: backupURL, options: .atomic)
        } else {
            try data.write(to: backupURL, options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    public func update(_ transform: (inout LocalLibrary) throws -> Void) throws -> LocalLibrary {
        var library = try load()
        try transform(&library)
        try save(library)
        return library
    }
}
