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

enum NightwingAccent: String, CaseIterable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .graphite: "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .system: Self.systemAccentColor
        case .blue: Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
        case .purple: Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255)
        case .pink: Color(red: 255 / 255, green: 45 / 255, blue: 85 / 255)
        case .red: Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255)
        case .orange: Color(red: 255 / 255, green: 149 / 255, blue: 0 / 255)
        case .yellow: Color(red: 255 / 255, green: 204 / 255, blue: 0 / 255)
        case .green: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
        case .graphite: Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
        }
    }

    var swatch: AnyShapeStyle {
        if self == .system {
            return AnyShapeStyle(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                center: .center
            ))
        }
        return AnyShapeStyle(color)
    }

    var usesLightCheckmark: Bool {
        self != .yellow && self != .orange
    }

    private static var systemAccentColor: Color {
        #if os(macOS)
        let accentNumber = (UserDefaults.standard.object(forKey: "AppleAccentColor") as? NSNumber)?.intValue
        switch accentNumber {
        case -1: return NightwingAccent.graphite.color
        case 0: return NightwingAccent.red.color
        case 1: return NightwingAccent.orange.color
        case 2: return NightwingAccent.yellow.color
        case 3: return NightwingAccent.green.color
        case 5: return NightwingAccent.purple.color
        case 6: return NightwingAccent.pink.color
        default: return NightwingAccent.blue.color
        }
        #else
        return NightwingAccent.blue.color
        #endif
    }
}

enum NightwingTheme {
    static let background = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let sidebar = Color(red: 14 / 255, green: 14 / 255, blue: 14 / 255)
    static let panel = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
    static let panelElevated = Color(red: 40 / 255, green: 40 / 255, blue: 40 / 255)
    static var action: Color {
        let storedValue = UserDefaults.standard.string(forKey: "nightwing.accentColor")
        return (storedValue.flatMap(NightwingAccent.init(rawValue:)) ?? .blue).color
    }
    static let rowHover = Color.white.opacity(0.10)
    static let divider = Color.white.opacity(0.12)
    static let glassTint = Color.white.opacity(0.035)
    static let glassElevatedTint = Color.white.opacity(0.075)
    static var glassPressedTint: Color { action.opacity(0.14) }
    static let glassStroke = Color.white.opacity(0.15)
    static let glassInnerStroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 179 / 255, green: 179 / 255, blue: 179 / 255)
    static let warning = Color(red: 255 / 255, green: 170 / 255, blue: 56 / 255)

    static var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255),
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

    var isOnlineDownloadedAlbum: Bool {
        tracks.contains { track in
            track.fileURL.standardizedFileURL.path.contains("/Nightwing/Online Downloads/Albums/")
        }
    }

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
            #if os(macOS)
            Button(track.lyricsMetadata?.status == .ready ? "Regenerate Lyrics" : "Generate Lyrics", systemImage: "quote.bubble") {
                appModel.generateLyrics(for: track)
            }
            #endif
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
    var showLyrics: (() -> Void)?

    init(showsQueue: Binding<Bool>? = nil, showLyrics: (() -> Void)? = nil) {
        self.showsQueue = showsQueue
        self.showLyrics = showLyrics
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
            PlaybackSpeedMenu()
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)

            ShuffleButton()

            Button {
                try? player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NightwingTransportButtonStyle())
            .foregroundStyle(NightwingTheme.secondaryText)
            .accessibilityLabel("Previous")

            Button {
                appModel.togglePlayback()
            } label: {
                Image(systemName: showsPauseState ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(NightwingTransportButtonStyle(isPrimary: true))
            .foregroundStyle(NightwingTheme.primaryText)
            .accessibilityLabel(showsPauseState ? "Pause" : "Play")

            Button {
                try? player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NightwingTransportButtonStyle())
            .foregroundStyle(NightwingTheme.secondaryText)
            .accessibilityLabel("Next")

            RepeatButton()

            PlaybackSpeedMenu()
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                Button {
                    showLyrics?()
                } label: {
                    Image(systemName: "quote.bubble")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(currentDisplayTrack == nil ? NightwingTheme.secondaryText.opacity(0.5) : NightwingTheme.secondaryText)
                .disabled(currentDisplayTrack == nil)
                .help("Lyrics")
                .accessibilityLabel("Lyrics")

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
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                NightwingArtworkView(track: currentDisplayTrack, size: 42, cornerRadius: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTitle)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .lineLimit(1)

                    Text(currentSubtitle)
                        .font(.caption)
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    appModel.togglePlayback()
                } label: {
                    Image(systemName: showsPauseState ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPauseState ? "Pause" : "Play")

                Button {
                    try? player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .frame(width: 32, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.white.opacity(0.86))
                        .frame(width: proxy.size.width * mobileProgressFraction)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(Int(mobileProgressFraction * 100)) percent")
        }
        .background(NightwingTheme.panel)
    }

    private var mobileProgressFraction: CGFloat {
        guard player.state.duration > 0 else { return 0 }
        return CGFloat(min(max(player.state.currentTime / player.state.duration, 0), 1))
    }
}

private struct NightwingTransportButtonStyle: ButtonStyle {
    @State private var isHovering = false
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : (isHovering ? 1.1 : 1))
            .brightness(isHovering ? 0.18 : 0)
            .background(
                Circle()
                    .fill(NightwingTheme.rowHover.opacity(isHovering && !isPrimary ? 1 : 0))
            )
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct LyricsPanel: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    let track: Track?

    private var document: LyricsDocument? {
        appModel.lyricsDocument(for: track)
    }

    private var isGenerating: Bool {
        appModel.isGeneratingLyrics(for: track)
    }

    private var activeLineID: LyricsLine.ID? {
        document?.activeLineIndex(at: player.state.currentTime).flatMap { index in
            document?.lines[index].id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            #if os(macOS)
            if !appModel.queuedLyricsTrackIDs.isEmpty {
                DisclosureGroup("Queued songs (\(appModel.queuedLyricsTrackIDs.count))") {
                    ForEach(appModel.queuedLyricsTrackIDs, id: \.self) { id in
                        if let queuedTrack = appModel.track(id: id) {
                            HStack {
                                Text(queuedTrack.title).lineLimit(1)
                                Spacer()
                                Button("Cancel") { appModel.cancelLyricsGeneration(for: queuedTrack) }
                            }
                        }
                    }
                }
            }
            if let progress = appModel.lyricsLibraryGenerationProgress {
                libraryGenerationStatus(progress)
            }
            #endif

            if let document, !document.lines.isEmpty {
                lyricLines(document)
            } else {
                emptyState
            }
        }
        .padding(20)
        .task(id: track?.id) {
            await appModel.prepareLyricsForDisplay(for: track)
        }
    }

    #if os(macOS)
    private func libraryGenerationStatus(_ progress: LyricsLibraryGenerationProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Creating lyrics for your library")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(progress.completed) of \(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NightwingTheme.secondaryText)
            }
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            if let title = progress.currentTrackTitle {
                Text("Working on \(title)")
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    #endif

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Lyrics")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(NightwingTheme.primaryText)

                Text(track?.title ?? "Nothing Playing")
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            #if os(macOS)
            if let track {
                headerAction(for: track)
            }
            #endif
        }
    }

    #if os(macOS)
    @ViewBuilder
    private func headerAction(for track: Track) -> some View {
        if isGenerating {
            Button {
                appModel.cancelLyricsGeneration(for: track)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Stop generating lyrics")
            .accessibilityLabel("Stop generating lyrics")
        } else {
            switch appModel.lyricsModelState {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .help("Checking for the lyrics model")
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 90)
                    .help("Downloading the lyrics model")
            case .notDownloaded, .failed:
                Button {
                    appModel.downloadLyricsModel()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Download lyrics model")
                .accessibilityLabel("Download lyrics model")
            case .ready:
                Button {
                    appModel.generateLyrics(for: track)
                } label: {
                    Image(systemName: document == nil ? "waveform.badge.magnifyingglass" : "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(document == nil ? "Generate lyrics" : "Regenerate lyrics")
                .accessibilityLabel(document == nil ? "Generate lyrics" : "Regenerate lyrics")
            }
        }
    }
    #endif

    private func lyricLines(_ document: LyricsDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(document.lines) { line in
                        Button {
                            appModel.seek(to: line.startTime)
                        } label: {
                            Text(line.text)
                                .font(line.id == activeLineID ? .title3.weight(.bold) : .title3.weight(.semibold))
                                .foregroundStyle(line.id == activeLineID ? NightwingTheme.primaryText : NightwingTheme.secondaryText)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .accessibilityHint("Seek to this lyric")
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: activeLineID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.snappy(duration: 0.24)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            if isGenerating, case .downloading = appModel.lyricsModelState {
                lyricsModelSupportState
            } else if isGenerating || track?.lyricsMetadata?.status == .failed {
                readyModelEmptyState
            } else if appModel.lyricsModelState != .ready {
                lyricsModelSupportState
            } else {
                readyModelEmptyState
            }
            #else
            readyModelEmptyState
            #endif

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var readyModelEmptyState: some View {
        if isGenerating {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(track.flatMap { appModel.lyricsTranscriptionProgress[$0.id] }.map {
                    $0 >= 1 ? "Finishing lyrics..." : "Creating lyrics… \($0.formatted(.percent.precision(.fractionLength(0))))"
                } ?? (track.map { appModel.queuedLyricsTrackIDs.contains($0.id) } == true ? "Queued for lyrics…" : "Preparing lyrics…"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NightwingTheme.secondaryText)
            }
        } else if let track {
            Text(track.lyricsMetadata?.status == .failed ? "Lyrics could not be created." : "No lyrics yet.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(NightwingTheme.secondaryText)

            #if os(macOS)
            Button {
                appModel.generateLyrics(for: track)
            } label: {
                Label("Retry Lyrics", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            #endif

            if let error = track.lyricsMetadata?.errorDescription,
               track.lyricsMetadata?.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .textSelection(.enabled)
            }
        } else {
            Text("Play a song to see its lyrics here.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(NightwingTheme.secondaryText)
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var lyricsModelSupportState: some View {
        switch appModel.lyricsModelState {
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for the lyrics model...")
                    .font(.callout)
                    .foregroundStyle(NightwingTheme.secondaryText)
            }
        case .notDownloaded:
            modelDownloadPrompt(message: nil)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 10) {
                Text("Downloading the lyrics model")
                    .font(.title3.weight(.semibold))
                Text("\(appModel.lyricsModelDownloadedSizeText(progress: progress)) of \(appModel.lyricsModelSizeText) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(NightwingTheme.secondaryText)
                ProgressView(value: progress)
                    .frame(maxWidth: 420)
                Text("Keep Nightwing open while the download finishes. Lyrics will then be created for the songs already in your library.")
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
            }
        case .failed(let message):
            modelDownloadPrompt(message: message)
        case .ready:
            EmptyView()
        }
    }

    private func modelDownloadPrompt(message: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create lyrics for your music")
                .font(.title3.weight(.semibold))
                .foregroundStyle(NightwingTheme.primaryText)
            Text("Download a lyrics model to support lyric generation. It runs privately on your Mac and lets Nightwing create lyrics without uploading your music.")
                .font(.callout)
                .foregroundStyle(NightwingTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Download size: about \(appModel.lyricsModelSizeText)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(NightwingTheme.primaryText)
            Text("After the download, Nightwing will automatically start creating lyrics for songs already in your library.")
                .font(.caption)
                .foregroundStyle(NightwingTheme.secondaryText)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Button {
                appModel.downloadLyricsModel()
            } label: {
                Label("Download Lyrics Model", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
    #endif
}

struct PlaybackSpeedMenu: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var isPickerPresented = false

    var isCompact = false

    var body: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                PlaybackSpeedFormulaView(speed: player.state.profile.clampedSpeed, size: isCompact ? 12 : 13, weight: .bold)
                    .fixedSize()

                if !isCompact {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                }
            }
            .foregroundStyle(NightwingTheme.primaryText)
            .padding(.horizontal, isCompact ? 8 : 10)
            .frame(minHeight: isCompact ? 28 : 30)
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
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            PlaybackSpeedPickerPopover {
                isPickerPresented = false
            }
            .environmentObject(player)
        }
    }
}

private struct PlaybackSpeedPickerPopover: View {
    @EnvironmentObject private var player: PlayerEngine

    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback Speed")
                .font(.caption.weight(.bold))
                .foregroundStyle(NightwingTheme.secondaryText)

            VStack(spacing: 2) {
                ForEach(PlaybackProfile.speedPresets) { preset in
                    Button {
                        player.setSpeedPreset(preset)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isSelected(preset) ? NightwingTheme.action : Color.clear)
                                .frame(width: 16)

                            PlaybackSpeedFormulaView(semitoneOffset: preset.semitoneOffset, size: 15, weight: .semibold)
                                .frame(width: 66, alignment: .leading)

                            Text(presetSubtitle(for: preset))
                                .font(.callout)
                                .foregroundStyle(NightwingTheme.primaryText)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .background(isSelected(preset) ? NightwingTheme.action.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: preset))
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func isSelected(_ preset: PlaybackSpeedPreset) -> Bool {
        abs(player.state.profile.clampedSpeed - preset.speed) <= 0.006
    }

    private func isDefaultPreset(_ preset: PlaybackSpeedPreset) -> Bool {
        preset.semitoneOffset == Int(PlaybackProfile.nightcorePitchSemitones)
    }

    private func presetSubtitle(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "Original"
        }

        return "\(preset.title) st\(isDefaultPreset(preset) ? " - Default" : "")"
    }

    private func accessibilityLabel(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "1 times, original"
        }

        return "\(PlaybackProfile.speedLabel(for: preset.speed)), \(preset.title) semitones\(isDefaultPreset(preset) ? ", default" : "")"
    }
}

private struct PlaybackSpeedFormulaView: View {
    private let formula: PlaybackSpeedFormula
    private let size: CGFloat
    private let weight: Font.Weight

    init(speed: Double, size: CGFloat = 13, weight: Font.Weight = .semibold) {
        formula = PlaybackSpeedFormula(speed: speed)
        self.size = size
        self.weight = weight
    }

    init(semitoneOffset: Int, size: CGFloat = 13, weight: Font.Weight = .semibold) {
        formula = PlaybackSpeedFormula(semitoneOffset: semitoneOffset)
        self.size = size
        self.weight = weight
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
            if formula.isApproximate {
                Text("≈")
                    .font(.system(size: size, weight: weight))
            }

            formulaBody

            Text("x")
                .font(.system(size: size, weight: weight))
        }
        .accessibilityLabel(formula.accessibilityLabel)
    }

    @ViewBuilder
    private var formulaBody: some View {
        switch formula.kind {
        case .one:
            Text("1")
                .font(.system(size: size, weight: weight))
        case .squareRootTwo:
            Text("√2")
                .font(.system(size: size, weight: weight))
        case .whole(let value):
            Text("\(value)")
                .font(.system(size: size, weight: weight))
        case .power(let numerator, let denominator):
            HStack(alignment: .top, spacing: 1) {
                Text("2")
                    .font(.system(size: size, weight: weight))

                if denominator == 1 {
                    Text("\(numerator)")
                        .font(.system(size: size * 0.62, weight: weight))
                        .baselineOffset(size * 0.36)
                } else {
                    VStack(spacing: 0) {
                        Text("\(numerator)")
                            .font(.system(size: size * 0.52, weight: weight))
                        Rectangle()
                            .frame(width: fractionRuleWidth(numerator: numerator, denominator: denominator), height: 0.8)
                        Text("\(denominator)")
                            .font(.system(size: size * 0.52, weight: weight))
                    }
                    .offset(y: -size * 0.34)
                }
            }
        }
    }

    private func fractionRuleWidth(numerator: Int, denominator: Int) -> CGFloat {
        CGFloat(max(String(numerator).count, String(denominator).count)) * size * 0.32 + 4
    }
}

private struct PlaybackSpeedFormula {
    enum Kind {
        case one
        case whole(Int)
        case squareRootTwo
        case power(numerator: Int, denominator: Int)
    }

    let kind: Kind
    let isApproximate: Bool

    init(speed: Double) {
        let clampedSpeed = min(max(speed, 0.25), 4.0)

        if let preset = PlaybackProfile.speedPreset(matching: clampedSpeed) {
            self.init(semitoneOffset: preset.semitoneOffset, isApproximate: false)
            return
        }

        let roundedWholeSpeed = clampedSpeed.rounded()
        if abs(clampedSpeed - roundedWholeSpeed) <= 0.006 {
            self.init(kind: .whole(Int(roundedWholeSpeed)), isApproximate: false)
            return
        }

        let roundedCents = Int((1200.0 * log2(clampedSpeed)).rounded())
        self.init(numerator: roundedCents, denominator: 1200, isApproximate: true)
    }

    init(semitoneOffset: Int, isApproximate: Bool = false) {
        self.init(numerator: semitoneOffset, denominator: 12, isApproximate: isApproximate)
    }

    private init(kind: Kind, isApproximate: Bool) {
        self.kind = kind
        self.isApproximate = isApproximate
    }

    private init(numerator: Int, denominator: Int, isApproximate: Bool) {
        let divisor = Self.greatestCommonDivisor(abs(numerator), abs(denominator))
        let simplifiedNumerator = numerator / divisor
        let simplifiedDenominator = denominator / divisor

        self.isApproximate = isApproximate

        if simplifiedNumerator == 0 {
            kind = .one
        } else if simplifiedNumerator == simplifiedDenominator {
            kind = .whole(2)
        } else if simplifiedNumerator == 1 && simplifiedDenominator == 2 {
            kind = .squareRootTwo
        } else {
            kind = .power(numerator: simplifiedNumerator, denominator: simplifiedDenominator)
        }
    }

    var accessibilityLabel: String {
        let prefix = isApproximate ? "approximately " : ""

        switch kind {
        case .one:
            return "\(prefix)1 times"
        case .whole(let value):
            return "\(prefix)\(value) times"
        case .squareRootTwo:
            return "\(prefix)root 2 times"
        case .power(let numerator, let denominator):
            if denominator == 1 {
                return "\(prefix)2 to the \(numerator) times"
            }

            return "\(prefix)2 to the \(numerator) over \(denominator) times"
        }
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs

        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }

        return max(a, 1)
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
                PlaybackSpeedMenu()
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

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

                RepeatButton()

                PlaybackSpeedMenu()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .buttonStyle(.plain)

            VolumeControlView()
                .frame(maxWidth: 320)
        }
    }
}

struct NightcoreControlPanel: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var isExpanded: Bool

    init(initiallyExpanded: Bool = true) {
        _isExpanded = State(initialValue: initiallyExpanded)
    }

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
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Label("Nightcore", systemImage: "sparkles")
                        .font(.headline)

                    Spacer(minLength: 8)

                    if player.state.profile.isNightcoreEnabled {
                        HStack(spacing: 4) {
                            Text("Speeding up by")
                                .font(.callout.weight(.semibold))
                            PlaybackSpeedFormulaView(speed: player.state.profile.clampedSpeed, size: 14, weight: .semibold)
                        }
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    } else {
                        Text("Original speed")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(NightwingTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse Nightcore controls" : "Expand Nightcore controls")

            if isExpanded {
                HStack {
                    Text("Enabled")
                        .font(.callout)
                    Spacer()
                    Toggle("Nightcore", isOn: nightcoreEnabled)
                        .labelsHidden()
                }

                NightcoreSpeedPresetGrid()

                LabeledContent("Custom speed") {
                    PlaybackSpeedFormulaView(speed: player.state.profile.clampedSpeed, size: 14, weight: .semibold)
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
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct NightcoreSpeedPresetGrid: View {
    @EnvironmentObject private var player: PlayerEngine

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed preset")
                .font(.callout.weight(.semibold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(PlaybackProfile.speedPresets) { preset in
                    Button {
                        player.setSpeedPreset(preset)
                    } label: {
                        VStack(spacing: 2) {
                            PlaybackSpeedFormulaView(semitoneOffset: preset.semitoneOffset, size: 15, weight: .bold)
                                .lineLimit(1)

                            Text(presetSubtitle(for: preset))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isSelected(preset) ? .black.opacity(0.72) : NightwingTheme.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(isSelected(preset) ? .black : NightwingTheme.primaryText)
                        .background(isSelected(preset) ? NightwingTheme.action : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isDefaultPreset(preset) ? NightwingTheme.action.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: preset))
                }
            }
        }
    }

    private func isSelected(_ preset: PlaybackSpeedPreset) -> Bool {
        abs(player.state.profile.clampedSpeed - preset.speed) <= 0.006
    }

    private func isDefaultPreset(_ preset: PlaybackSpeedPreset) -> Bool {
        preset.semitoneOffset == Int(PlaybackProfile.nightcorePitchSemitones)
    }

    private func presetSubtitle(for preset: PlaybackSpeedPreset) -> String {
        if preset.semitoneOffset == 0 {
            return "Original"
        }

        return "\(preset.title) st\(isDefaultPreset(preset) ? " default" : "")"
    }

    private func accessibilityLabel(for preset: PlaybackSpeedPreset) -> String {
        if isDefaultPreset(preset) {
            return "\(PlaybackProfile.speedLabel(for: preset.speed)), default speed, \(preset.title) semitones"
        }

        return "\(PlaybackProfile.speedLabel(for: preset.speed)), \(preset.title) semitones"
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

struct LibraryRecoveryBanner: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    var body: some View {
        if let message = appModel.libraryRecoveryMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                Text(message).font(.callout)
                Spacer()
                if appModel.libraryNeedsRecovery {
                    Button("Retry") { Task { await appModel.loadLibrary() } }
                } else {
                    Button("Dismiss") { appModel.dismissLibraryRecoveryNotice() }
                }
            }
            .padding(12)
            .background(.orange.opacity(0.16))
        }
    }
}
