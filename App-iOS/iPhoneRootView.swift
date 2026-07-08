import SwiftUI
import UniformTypeIdentifiers

struct iPhoneRootView: View {
    var body: some View {
        NavigationStack {
            iPhoneLibraryHomeView()
        }
        .background(Color.nwBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .background(Color.nwBackground.opacity(0.96))
        }
        .tint(.white)
    }
}

private struct iPhoneLibraryHomeView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @State private var searchText = ""
    @State private var showsFileImporter = false
    @State private var showsFolderImporter = false

    private var albums: [LibraryAlbumGroup] {
        appModel.filteredAlbumGroups(matching: searchText)
    }

    private var featuredAlbums: [LibraryAlbumGroup] {
        Array(appModel.albumGroups.prefix(6))
    }

    private let albumColumns = [
        GridItem(.adaptive(minimum: 154), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                importActions

                if appModel.albumGroups.isEmpty {
                    iPhoneEmptyLibraryView(
                        importFiles: { showsFileImporter = true },
                        importFolder: { showsFolderImporter = true }
                    )
                } else {
                    if !featuredAlbums.isEmpty, searchText.isEmpty {
                        featuredSection
                    }

                    playlistsSection
                    albumGrid
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.nwBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.nwBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(text: $searchText, prompt: "Artists, albums, songs")
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                appModel.importFiles(urls)
            }
        }
        .fileImporter(
            isPresented: $showsFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let folderURL = urls.first {
                appModel.importFolder(folderURL)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Good evening")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                if appModel.isImporting {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 34, height: 34)
                }
            }

            HStack(spacing: 8) {
                iPhoneFilterPill(title: "Home", isSelected: true)
                iPhoneFilterPill(title: "Your Library", isSelected: false)
                iPhoneFilterPill(title: "\(appModel.albumGroups.count) Albums", isSelected: false)
            }
        }
    }

    private var importActions: some View {
        HStack(spacing: 12) {
            iPhoneImportActionButton(
                title: "Add Files",
                subtitle: "Pick songs",
                systemImage: "plus"
            ) {
                showsFileImporter = true
            }

            iPhoneImportActionButton(
                title: "Add Folder",
                subtitle: "Import albums",
                systemImage: "folder.badge.plus"
            ) {
                showsFolderImporter = true
            }
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump back in")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(featuredAlbums) { album in
                    NavigationLink {
                        iPhoneAlbumDetailView(albumID: album.id)
                    } label: {
                        iPhoneQuickAlbumTile(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var albumGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(searchText.isEmpty ? "Your albums" : "Search results")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()

                if !albums.isEmpty {
                    Text("\(albums.count)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if albums.isEmpty {
                iPhoneNoResultsView()
            } else {
                LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 18) {
                    ForEach(albums) { album in
                        NavigationLink {
                            iPhoneAlbumDetailView(albumID: album.id)
                        } label: {
                            iPhoneAlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playlists")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    _ = appModel.createPlaylist()
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(Color.nwSpotifyGreen, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Playlist")
            }

            if appModel.library.playlists.isEmpty {
                Text("Create a playlist, then add songs from any album.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .nightwingGlass(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(appModel.library.playlists) { playlist in
                            NavigationLink {
                                iPhonePlaylistDetailView(playlistID: playlist.id)
                            } label: {
                                iPhonePlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}

private struct iPhoneAlbumDetailView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let albumID: LibraryAlbumGroup.ID

    var body: some View {
        Group {
            if let album = appModel.albumGroup(id: albumID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        iPhoneAlbumHero(album: album) {
                            appModel.playAlbum(album)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(album.tracks) { track in
                                iPhoneTrackRow(track: track) {
                                    appModel.play(
                                        track,
                                        within: album.tracks,
                                        preloadLookaheadCount: album.tracks.count
                                    )
                                }
                                .contextMenu {
                                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                        appModel.playNext(track)
                                    }
                                    Button("Add to Queue", systemImage: "text.badge.plus") {
                                        appModel.enqueue(track)
                                    }
                                    if !appModel.library.playlists.isEmpty {
                                        Menu("Add to Playlist", systemImage: "music.note.list") {
                                            ForEach(appModel.library.playlists) { playlist in
                                                Button(playlist.name) {
                                                    appModel.add(track, to: playlist)
                                                }
                                            }
                                        }
                                    }
                                    Button("New Playlist from Song", systemImage: "plus") {
                                        _ = appModel.createPlaylist(named: track.title, adding: track)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 22)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.nwBackground)
                .navigationTitle(album.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
            } else {
                iPhoneMissingAlbumView()
            }
        }
    }
}

private struct iPhonePlaylistDetailView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let playlistID: Playlist.ID

    private var playlist: Playlist? {
        appModel.playlist(id: playlistID)
    }

    private var entries: [PlaylistTrackEntry] {
        playlist.map { appModel.playlistTrackEntries(for: $0) } ?? []
    }

    var body: some View {
        Group {
            if let playlist {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        iPhonePlaylistHero(
                            playlist: playlist,
                            trackCount: entries.count,
                            duration: entries.map(\.track).compactMap(\.duration).reduce(0, +)
                        ) {
                            appModel.playPlaylist(playlist)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            if entries.isEmpty {
                                Text("Add songs from album menus.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            } else {
                                ForEach(entries) { entry in
                                    iPhoneTrackRow(track: entry.track) {
                                        appModel.play(entry.track, within: entries.map(\.track))
                                    }
                                    .contextMenu {
                                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                            appModel.playNext(entry.track)
                                        }
                                        Button("Add to Queue", systemImage: "text.badge.plus") {
                                            appModel.enqueue(entry.track)
                                        }
                                        Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                                            appModel.removePlaylistItem(entry.item, from: playlist)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 22)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.nwBackground)
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
            } else {
                iPhoneMissingAlbumView()
            }
        }
    }
}

private struct iPhoneFilterPill: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(isSelected ? .black : .white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if !isSelected {
                    Capsule()
                        .fill(.ultraThinMaterial)
                }
            }
            .background(isSelected ? Color.nwSpotifyGreen : NightwingTheme.glassElevatedTint, in: Capsule())
            .overlay {
                if !isSelected {
                    Capsule()
                        .stroke(NightwingTheme.glassStroke, lineWidth: 1)
                }
            }
    }
}

private struct iPhoneImportActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Color.nwSpotifyGreen, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nightwingGlass(RoundedRectangle(cornerRadius: 8, style: .continuous), isElevated: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct iPhoneQuickAlbumTile: View {
    let album: LibraryAlbumGroup

    var body: some View {
        HStack(spacing: 10) {
            NightwingArtworkView(album: album, size: 56, cornerRadius: 6)

            Text(album.title)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .frame(height: 56)
        .nightwingGlass(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct iPhoneAlbumCard: View {
    let album: LibraryAlbumGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            NightwingArtworkView(album: album, size: 154, cornerRadius: 7)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(album.title)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text("\(album.artistSummary) • \(album.trackCountText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .padding(10)
    }
}

private struct iPhonePlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            NightwingArtworkPlaceholder(size: 124, cornerRadius: 7, systemImage: "music.note.list")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(playlist.name)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text("\(playlist.items.count) track\(playlist.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 144, alignment: .leading)
        .contentShape(Rectangle())
        .padding(10)
    }
}

private struct iPhoneAlbumHero: View {
    @EnvironmentObject private var player: PlayerEngine

    let album: LibraryAlbumGroup
    let playAlbum: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                NightwingArtworkView(album: album, size: 226, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.36), radius: 22, x: 0, y: 14)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title)
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)

                Text(album.artistSummary)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                Text("\(album.trackCountText) • \(album.durationText(playbackRate: player.state.playbackDisplayRate))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 14) {
                Button(action: playAlbum) {
                    Image(systemName: "play.fill")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.black)
                        .frame(width: 58, height: 58)
                        .background(Color.nwSpotifyGreen, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play album")

                Text("Play Album")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 26)
        .background {
            LinearGradient(
                colors: [
                    Color.nwHeaderTop,
                    Color.nwHeaderMid,
                    Color.nwBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct iPhonePlaylistHero: View {
    @EnvironmentObject private var player: PlayerEngine

    let playlist: Playlist
    let trackCount: Int
    let duration: TimeInterval
    let playPlaylist: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                NightwingArtworkPlaceholder(size: 226, cornerRadius: 10, systemImage: "music.note.list")
                    .shadow(color: .black.opacity(0.36), radius: 22, x: 0, y: 14)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name)
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)

                Text("Playlist")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                Text("\(trackCount) track\(trackCount == 1 ? "" : "s") • \(formattedSpeedAdjustedDuration(duration, playbackRate: player.state.playbackDisplayRate))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 14) {
                Button(action: playPlaylist) {
                    Image(systemName: "play.fill")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.black)
                        .frame(width: 58, height: 58)
                        .background(Color.nwSpotifyGreen, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(trackCount == 0)
                .opacity(trackCount == 0 ? 0.5 : 1)
                .accessibilityLabel("Play playlist")

                Text("Play Playlist")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 26)
        .background {
            LinearGradient(
                colors: [
                    Color.nwHeaderTop,
                    Color.nwHeaderMid,
                    Color.nwBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct iPhoneTrackRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    let track: Track
    let play: () -> Void

    private var isCurrent: Bool {
        appModel.isCurrentTrack(track)
    }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ZStack {
                    if isCurrent && (player.state.isPlaying || appModel.isPlaybackStarting) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.nwSpotifyGreen)
                    } else {
                        Text(trackNumberText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.nwSpotifyGreen : (track.availability == .available ? .white : .secondary))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if track.availability != .available {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        Text(track.displayArtist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                Text(formattedSpeedAdjustedDuration(track.duration, playbackRate: player.state.playbackDisplayRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(isCurrent ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(track.title)")
    }

    private var trackNumberText: String {
        track.trackNumber.map(String.init) ?? "-"
    }
}

private struct iPhoneArtworkBlock: View {
    let size: CGFloat?
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size.map { max(18, $0 * 0.32) } ?? 44, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct iPhoneEmptyLibraryView: View {
    let importFiles: () -> Void
    let importFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            iPhoneArtworkBlock(size: 132, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Build your local library")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Add audio files or choose a folder. Folders are grouped into albums automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Add Files", systemImage: "plus", action: importFiles)
                    .buttonStyle(iPhonePrimaryCapsuleButtonStyle())
                Button("Add Folder", systemImage: "folder.badge.plus", action: importFolder)
                    .buttonStyle(iPhoneSecondaryCapsuleButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct iPhoneNoResultsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matches")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text("Try searching by album, artist, song title, genre, or file name.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct iPhoneMissingAlbumView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Album Missing")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("This album is no longer in the local library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.nwBackground)
    }
}

private struct iPhonePrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.nwSpotifyGreen.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

private struct iPhoneSecondaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .background(configuration.isPressed ? NightwingTheme.glassPressedTint : NightwingTheme.glassElevatedTint, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(NightwingTheme.glassStroke, lineWidth: 1)
            }
    }
}

private extension Color {
    static let nwBackground = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let nwHeaderTop = Color(red: 0.22, green: 0.36, blue: 0.29)
    static let nwHeaderMid = Color(red: 0.09, green: 0.12, blue: 0.105)
    static let nwSpotifyGreen = Color(red: 0.12, green: 0.84, blue: 0.38)
}

struct iPhoneRootView_Previews: PreviewProvider {
    static var previews: some View {
        iPhoneRootView()
    }
}
