import Foundation

public enum LibraryAvailability: String, Codable, Sendable {
    case available
    case missing
    case accessDenied
    case unsupported
    case unavailable
}
