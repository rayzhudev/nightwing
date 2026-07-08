import Foundation

struct NightwingUITrack: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let fileType: String
    let isAvailable: Bool

    var durationText: String {
        let totalSeconds = Int(duration.rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

struct NightwingUIPlaylist: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let detail: String
}

enum NightwingSampleData {
    static let tracks: [NightwingUITrack] = [
        NightwingUITrack(title: "Crystal Voltage", artist: "Local File", album: "Night Drive", duration: 213, fileType: "m4a", isAvailable: true),
        NightwingUITrack(title: "Afterimage", artist: "Ray Library", album: "Sketches", duration: 188, fileType: "mp3", isAvailable: true),
        NightwingUITrack(title: "Signal Bloom", artist: "Imported Folder", album: "Loose Tracks", duration: 241, fileType: "flac", isAvailable: true),
        NightwingUITrack(title: "Missing Demo", artist: "Relink Needed", album: "Unavailable", duration: 204, fileType: "wav", isAvailable: false)
    ]

    static let playlists: [NightwingUIPlaylist] = [
        NightwingUIPlaylist(name: "Nightcore Queue", detail: "Fast, bright local tracks"),
        NightwingUIPlaylist(name: "Recently Added", detail: "Imported files appear here"),
        NightwingUIPlaylist(name: "Late Walk", detail: "Personal playlist placeholder")
    ]
}
