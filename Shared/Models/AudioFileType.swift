import Foundation

public enum AudioFileType: String, Codable, CaseIterable, Sendable {
    case mp3
    case m4a
    case aac
    case alac
    case wav
    case aif
    case aiff
    case caf
    case flac

    public init?(fileExtension: String) {
        let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(rawValue: normalizedExtension)
    }

    public var fileExtension: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A"
        case .aac: "AAC"
        case .alac: "ALAC"
        case .wav: "WAV"
        case .aif: "AIFF"
        case .aiff: "AIFF"
        case .caf: "CAF"
        case .flac: "FLAC"
        }
    }

    public static let supportedExtensions: Set<String> = Set(allCases.map(\.rawValue))

    public static func isSupported(_ url: URL) -> Bool {
        AudioFileType(fileExtension: url.pathExtension) != nil
    }
}
