import SwiftUI
import UniformTypeIdentifiers

struct iPhoneRootView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @State private var selectedTab: iPhoneRootTab = .home
    @State private var showsNowPlaying = false
    @State private var showsAddMusic = false
    @State private var showsFileImporter = false
    @State private var showsFolderImporter = false

    var body: some View {
        ZStack {
            Color.nwBackground.ignoresSafeArea()

            selectedContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                MiniPlayerBar()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture {
                        showsNowPlaying = true
                    }

                iPhoneTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 8)
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.78))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsNowPlaying) {
            iPhoneNowPlayingSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsAddMusic) {
            iPhoneAddMusicSheet(
                importFiles: {
                    showsAddMusic = false
                    showsFileImporter = true
                },
                importFolder: {
                    showsAddMusic = false
                    showsFolderImporter = true
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .home:
            NavigationStack {
                iPhoneHomeView(
                    addMusic: { showsAddMusic = true },
                    selectTab: { selectedTab = $0 }
                )
            }
        case .library:
            NavigationStack {
                iPhoneLibraryView(addMusic: { showsAddMusic = true })
            }
        }
    }
}

private enum iPhoneRootTab: String, CaseIterable, Hashable {
    case home
    case library

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical.fill"
        }
    }
}

private struct iPhoneTabBar: View {
    @Binding var selectedTab: iPhoneRootTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(iPhoneRootTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20, weight: .bold))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.caption2.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selectedTab == tab ? .white : Color.white.opacity(0.58))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityValue(selectedTab == tab ? "Selected" : "")
            }
        }
        .frame(height: 48)
    }
}

private struct iPhoneHomeView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let addMusic: () -> Void
    let selectTab: (iPhoneRootTab) -> Void

    private var albums: [LibraryAlbumGroup] {
        appModel.albumGroups
    }

    private var featuredAlbum: LibraryAlbumGroup? {
        albums.first
    }

    private var quickAlbums: [LibraryAlbumGroup] {
        Array(albums.prefix(6))
    }

    private var recentTracks: [Track] {
        Array(appModel.recentlyAddedTracks.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                iPhoneTopBar(
                    title: greeting,
                    trailingButtons: [
                        iPhoneTopBarButton(systemImage: "magnifyingglass") {
                            selectTab(.library)
                        },
                        iPhoneTopBarButton(systemImage: "plus") {
                            addMusic()
                        }
                    ]
                )

                if appModel.library.tracks.isEmpty {
                    iPhoneEmptyLibraryView(
                        action: addMusic
                    )
                } else {
                    if let featuredAlbum {
                        iPhoneFeaturedAlbumPanel(album: featuredAlbum) {
                            appModel.playAlbum(featuredAlbum)
                        }
                    }

                    if !quickAlbums.isEmpty {
                        iPhoneSection(title: "Jump back in") {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(quickAlbums) { album in
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

                    if !recentTracks.isEmpty {
                        iPhoneSection(title: "Recently added") {
                            LazyVStack(spacing: 2) {
                                ForEach(recentTracks) { track in
                                    iPhoneTrackRow(track: track, showsArtwork: true) {
                                        appModel.play(track, within: recentTracks)
                                    }
                                }
                            }
                        }
                    }

                    if !appModel.library.playlists.isEmpty {
                        iPhoneSection(title: "Your playlists") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(appModel.library.playlists) { playlist in
                                        NavigationLink {
                                            iPhonePlaylistDetailView(playlistID: playlist.id)
                                        } label: {
                                            iPhonePlaylistCard(playlist: playlist)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 18)
                            }
                            .padding(.horizontal, -18)
                        }
                    }

                    iPhoneAddMusicRow(action: addMusic)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 136)
        }
        .scrollContentBackground(.hidden)
        .background(Color.nwBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

private enum iPhoneLibraryScope: String, CaseIterable {
    case albums = "Albums"
    case playlists = "Playlists"
    case songs = "Songs"
}

private enum iPhoneLibrarySort: String, CaseIterable {
    case title = "Title"
    case artist = "Artist"
}

private struct iPhoneLibraryView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let addMusic: () -> Void

    @State private var selectedScope: iPhoneLibraryScope = .albums
    @State private var sortMode: iPhoneLibrarySort = .title
    @State private var searchText = ""

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTracks: [Track] {
        sortedTracks(appModel.filteredTracks(matching: trimmedSearchText))
    }

    private var visibleAlbums: [LibraryAlbumGroup] {
        appModel.filteredAlbumGroups(matching: trimmedSearchText)
    }

    private var visiblePlaylists: [Playlist] {
        guard !trimmedSearchText.isEmpty else { return appModel.library.playlists }
        let query = trimmedSearchText.lowercased()
        return appModel.library.playlists.filter { $0.name.lowercased().contains(query) }
    }

    private var songSectionLetters: [String] {
        songSections.map(\.letter)
    }

    private var songSections: [(letter: String, tracks: [Track])] {
        Dictionary(grouping: visibleTracks, by: sectionLetter(for:))
            .map { (letter: $0.key, tracks: $0.value) }
            .sorted { lhs, rhs in
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter < rhs.letter
            }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        iPhoneTopBar(
                            title: "Library",
                            trailingButtons: [
                                iPhoneTopBarButton(systemImage: "plus") {
                                    addMusic()
                                }
                            ]
                        )

                        iPhoneLibraryScopePicker(selectedScope: $selectedScope)

                        if selectedScope == .songs {
                            iPhoneSongSortPicker(sortMode: $sortMode)
                        }

                        switch selectedScope {
                        case .albums:
                            albumsList
                        case .playlists:
                            playlistsList
                        case .songs:
                            songsList
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 136)
                }
                .scrollContentBackground(.hidden)
                .background(Color.nwBackground)

                if selectedScope == .songs && !songSectionLetters.isEmpty {
                    iPhoneAlphabetIndex(letters: songSectionLetters) { letter in
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(songSectionID(for: letter), anchor: .top)
                        }
                    }
                    .padding(.trailing, 2)
                    .padding(.top, 124)
                    .padding(.bottom, 150)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .searchable(text: $searchText, prompt: "Search songs, artists, albums")
    }

    private var albumsList: some View {
        LazyVStack(spacing: 2) {
            if visibleAlbums.isEmpty {
                emptyLibrarySearchState
            }

            ForEach(visibleAlbums) { album in
                NavigationLink {
                    iPhoneAlbumDetailView(albumID: album.id)
                } label: {
                    iPhoneAlbumListRow(album: album)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var playlistsList: some View {
        LazyVStack(spacing: 2) {
            iPhoneImportRow(
                title: "New playlist",
                subtitle: "Start a playlist",
                systemImage: "plus"
            ) {
                _ = appModel.createPlaylist()
            }

            ForEach(visiblePlaylists) { playlist in
                NavigationLink {
                    iPhonePlaylistDetailView(playlistID: playlist.id)
                } label: {
                    iPhonePlaylistListRow(playlist: playlist)
                }
                .buttonStyle(.plain)
            }

            if visiblePlaylists.isEmpty {
                iPhoneEmptyText(
                    title: appModel.library.playlists.isEmpty ? "No playlists yet" : "No playlist matches",
                    subtitle: appModel.library.playlists.isEmpty ? "Create one from songs you like." : "Try a different search."
                )
            }
        }
    }

    private var songsList: some View {
        LazyVStack(spacing: 2) {
            if visibleTracks.isEmpty && appModel.library.tracks.isEmpty {
                iPhoneEmptyLibraryView(
                    action: addMusic
                )
            } else if visibleTracks.isEmpty {
                emptyLibrarySearchState
            } else {
                ForEach(songSections, id: \.letter) { section in
                    Text(section.letter)
                        .font(.caption.weight(.black))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(songSectionID(for: section.letter))

                    ForEach(section.tracks) { track in
                        iPhoneTrackRow(track: track, showsArtwork: true) {
                            appModel.play(track, within: visibleTracks)
                        }
                        .contextMenu {
                            iPhoneTrackMenu(track: track)
                        }
                    }
                }
            }
        }
        .padding(.trailing, selectedScope == .songs && !songSectionLetters.isEmpty ? 20 : 0)
    }

    private var emptyLibrarySearchState: some View {
        iPhoneEmptyText(title: "No matches", subtitle: "Try another title, artist, album, or playlist.")
    }

    private func sortedTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            switch sortMode {
            case .title:
                let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return lhs.displayArtist.localizedCaseInsensitiveCompare(rhs.displayArtist) == .orderedAscending
            case .artist:
                let artistComparison = lhs.displayArtist.localizedCaseInsensitiveCompare(rhs.displayArtist)
                if artistComparison != .orderedSame {
                    return artistComparison == .orderedAscending
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func sectionLetter(for track: Track) -> String {
        let source: String
        switch sortMode {
        case .title:
            source = track.title
        case .artist:
            source = track.displayArtist
        }

        guard let first = source.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "#"
        }

        let letter = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
    }

    private func songSectionID(for letter: String) -> String {
        "song-section-\(letter)"
    }
}

private struct iPhoneSongSortPicker: View {
    @Binding var sortMode: iPhoneLibrarySort

    var body: some View {
        Picker("Sort songs", selection: $sortMode) {
            ForEach(iPhoneLibrarySort.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Sort songs")
    }
}

private struct iPhoneAlphabetIndex: View {
    let letters: [String]
    let jumpToLetter: (String) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    jumpToLetter(letter)
                } label: {
                    Text(letter)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.nwAccent)
                        .frame(width: 22, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to \(letter)")
            }
        }
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.28), in: Capsule())
    }
}

private struct iPhoneAlbumDetailView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let albumID: LibraryAlbumGroup.ID

    var body: some View {
        Group {
            if let album = appModel.albumGroup(id: albumID) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        iPhoneAlbumHero(album: album) {
                            appModel.playAlbum(album)
                        }

                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                                iPhoneTrackRow(track: track, index: index + 1) {
                                    appModel.play(
                                        track,
                                        within: album.tracks,
                                        preloadLookaheadCount: album.tracks.count
                                    )
                                }
                                .contextMenu {
                                    iPhoneTrackMenu(track: track)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 136)
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

    private var tracks: [Track] {
        entries.map(\.track)
    }

    var body: some View {
        Group {
            if let playlist {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        iPhonePlaylistHero(
                            playlist: playlist,
                            trackCount: entries.count,
                            duration: tracks.compactMap(\.duration).reduce(0, +)
                        ) {
                            appModel.playPlaylist(playlist)
                        }

                        LazyVStack(alignment: .leading, spacing: 2) {
                            if entries.isEmpty {
                                iPhoneEmptyText(title: "Empty playlist", subtitle: "Add songs from album menus.")
                                    .padding(.horizontal, 8)
                            } else {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    iPhoneTrackRow(track: entry.track, index: index + 1) {
                                        appModel.play(entry.track, within: tracks)
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
                        .padding(.bottom, 136)
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

private struct iPhoneTrackMenu: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let track: Track

    var body: some View {
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

private struct iPhoneNowPlayingSheet: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

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

        return player.state.currentItem?.url.deletingLastPathComponent().lastPathComponent ?? "Choose a song from Library"
    }

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
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    NightwingArtworkView(track: currentDisplayTrack, size: 278, cornerRadius: 10)
                        .shadow(color: .black.opacity(0.42), radius: 26, x: 0, y: 16)
                        .padding(.top, 18)

                    VStack(spacing: 6) {
                        Text(currentTitle)
                            .font(.title2.weight(.black))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.76)

                        Text(currentSubtitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    iPhoneExpandedTransport(
                        currentTime: currentTimeBinding,
                        showsPauseState: showsPauseState,
                        togglePlayback: appModel.togglePlayback
                    )

                    LyricsPanel(track: currentDisplayTrack)
                        .frame(minHeight: 260, maxHeight: 360)

                    VStack(spacing: 18) {
                        VolumeControlView()
                        NightcoreControlPanel(initiallyExpanded: false)
                    }

                    iPhoneNowPlayingQueuePreview()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 34)
            }
            .background(Color.nwBackground.ignoresSafeArea())
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.nwBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline.weight(.bold))
                    }
                    .accessibilityLabel("Close Now Playing")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct iPhoneExpandedTransport: View {
    @EnvironmentObject private var player: PlayerEngine

    @Binding var currentTime: Double
    let showsPauseState: Bool
    let togglePlayback: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Slider(value: $currentTime, in: 0...max(player.state.duration, 1))
                .disabled(player.state.currentItem == nil)
                .accessibilityLabel("Playback position")

            HStack {
                Text(formattedDuration(player.state.speedAdjustedCurrentTime))
                Spacer()
                Text("-\(formattedDuration(player.state.speedAdjustedRemainingTime))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 26) {
                ShuffleButton(isCompact: true)

                Button {
                    try? player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2.weight(.bold))
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel("Previous")

                Button(action: togglePlayback) {
                    Image(systemName: showsPauseState ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 66, weight: .regular))
                        .frame(width: 74, height: 74)
                }
                .accessibilityLabel(showsPauseState ? "Pause" : "Play")

                Button {
                    try? player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2.weight(.bold))
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel("Next")

                RepeatButton(isCompact: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }
}

private struct iPhoneNowPlayingQueuePreview: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    private var upcomingItems: [PlaybackQueueItem] {
        guard let currentIndex = player.state.queue.currentIndex else {
            return Array(player.state.queue.items.prefix(8))
        }

        return Array(player.state.queue.items.dropFirst(currentIndex + 1).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)

            if upcomingItems.isEmpty {
                Text("Nothing queued after this song.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(upcomingItems) { item in
                        iPhoneQueuePreviewRow(item: item)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct iPhoneQueuePreviewRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let item: PlaybackQueueItem

    private var track: Track? {
        appModel.track(for: item)
    }

    var body: some View {
        HStack(spacing: 10) {
            NightwingArtworkView(track: track, size: 38, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? item.title ?? item.url.deletingPathExtension().lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(track?.displayArtist ?? item.url.deletingLastPathComponent().lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

private struct iPhoneAddMusicSheet: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @Environment(\.dismiss) private var dismiss

    let importFiles: () -> Void
    let importFolder: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                iPhoneAddMusicOption(
                    title: "Choose Songs",
                    subtitle: "Pick one or more audio files",
                    systemImage: "music.note"
                ) {
                    importFiles()
                }

                iPhoneAddMusicOption(
                    title: "Choose Folder",
                    subtitle: "Import a folder of albums or songs",
                    systemImage: "folder.badge.plus"
                ) {
                    importFolder()
                }

                iPhoneAddMusicOption(
                    title: "iPhone Music",
                    subtitle: "Import locally playable songs from Music",
                    systemImage: "iphone.gen3"
                ) {
                    dismiss()
                    appModel.importSystemMusicLibrary()
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color.nwBackground.ignoresSafeArea())
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.nwBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

private struct iPhoneAddMusicOption: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Color.nwAccent, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct iPhoneTopBar: View {
    let title: String
    var trailingButtons: [iPhoneTopBarButton] = []

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.largeTitle.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 8)

            ForEach(trailingButtons) { button in
                Button(action: button.action) {
                    Image(systemName: button.systemImage)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(button.accessibilityLabel)
            }
        }
    }
}

private struct iPhoneTopBarButton: Identifiable {
    let id = UUID()
    let systemImage: String
    var accessibilityLabel: String = "Action"
    let action: () -> Void
}

private struct iPhoneSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            content
        }
    }
}

private struct iPhoneLibraryScopePicker: View {
    @Binding var selectedScope: iPhoneLibraryScope

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(iPhoneLibraryScope.allCases, id: \.self) { scope in
                    Button {
                        selectedScope = scope
                    } label: {
                        Text(scope.rawValue)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(selectedScope == scope ? .black : .white)
                            .lineLimit(1)
                            .padding(.horizontal, 15)
                            .frame(height: 34)
                            .background(selectedScope == scope ? Color.nwAccent : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.horizontal, -18)
    }
}

private struct iPhoneFeaturedAlbumPanel: View {
    let album: LibraryAlbumGroup
    let playAlbum: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            NavigationLink {
                iPhoneAlbumDetailView(albumID: album.id)
            } label: {
                NightwingArtworkView(album: album, size: 116, cornerRadius: 7)
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("Made for now")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.nwAccent)
                    .textCase(.uppercase)

                NavigationLink {
                    iPhoneAlbumDetailView(albumID: album.id)
                } label: {
                    Text(album.title)
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text("\(album.artistSummary) • \(album.trackCountText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Button(action: playAlbum) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.black)
                            .frame(width: 44, height: 44)
                            .background(Color.nwAccent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(album.title)")

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    Color.nwHeaderTop,
                    Color.nwSurfaceRaised
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct iPhoneQuickAlbumTile: View {
    let album: LibraryAlbumGroup

    var body: some View {
        HStack(spacing: 10) {
            NightwingArtworkView(album: album, size: 58, cornerRadius: 5)

            Text(album.title)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .frame(height: 58)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct iPhoneAlbumListRow: View {
    let album: LibraryAlbumGroup

    var body: some View {
        HStack(spacing: 12) {
            NightwingArtworkView(album: album, size: 62, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Album • \(album.artistSummary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct iPhonePlaylistListRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            NightwingArtworkPlaceholder(size: 62, cornerRadius: 5, systemImage: "music.note.list")

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Playlist • \(playlist.items.count) track\(playlist.items.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct iPhonePlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NightwingArtworkPlaceholder(size: 142, cornerRadius: 7, systemImage: "music.note.list")

            Text(playlist.name)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text("\(playlist.items.count) track\(playlist.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 142, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct iPhoneTrackRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    let track: Track
    var index: Int?
    var showsArtwork = false
    let play: () -> Void

    private var isCurrent: Bool {
        appModel.isCurrentTrack(track)
    }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                leadingArtwork

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .bold : .semibold))
                        .foregroundStyle(isCurrent ? Color.nwAccent : (track.availability == .available ? .white : .secondary))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if track.availability != .available {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        Text("\(track.displayArtist) • \(formattedSpeedAdjustedDuration(track.duration, playbackRate: player.state.playbackDisplayRate))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 38)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isCurrent ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(track.title)")
    }

    @ViewBuilder
    private var leadingArtwork: some View {
        if showsArtwork {
            NightwingArtworkView(track: track, size: 48, cornerRadius: 5)
        } else {
            ZStack {
                if isCurrent && (player.state.isPlaying || appModel.isPlaybackStarting) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.nwAccent)
                } else {
                    Text(index.map(String.init) ?? trackNumberText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 48)
        }
    }

    private var trackNumberText: String {
        track.trackNumber.map(String.init) ?? "-"
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
                NightwingArtworkView(album: album, size: 232, cornerRadius: 8)
                    .shadow(color: .black.opacity(0.42), radius: 24, x: 0, y: 14)
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

            iPhonePlayActionRow(action: playAlbum, label: "Play Album", isDisabled: album.tracks.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 20)
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
                NightwingArtworkPlaceholder(size: 232, cornerRadius: 8, systemImage: "music.note.list")
                    .shadow(color: .black.opacity(0.42), radius: 24, x: 0, y: 14)
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

            iPhonePlayActionRow(action: playPlaylist, label: "Play Playlist", isDisabled: trackCount == 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 20)
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

private struct iPhonePlayActionRow: View {
    let action: () -> Void
    let label: String
    var isDisabled = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: action) {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.black)
                    .frame(width: 58, height: 58)
                    .background(Color.nwAccent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1)
            .accessibilityLabel(label)

            Text(label)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)

            Spacer()
        }
    }
}

private struct iPhoneImportRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Color.nwAccent, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct iPhoneAddMusicRow: View {
    let action: () -> Void

    var body: some View {
        iPhoneImportRow(
            title: "Add music",
            subtitle: "Files, folders, or iPhone Music",
            systemImage: "plus"
        ) {
            action()
        }
    }
}

private struct iPhoneCompactActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct iPhoneEmptyLibraryView: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iPhoneArtworkBlock(size: 92, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Build your library")
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                    Text("Add music from Files, folders, or your iPhone Music library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            iPhoneCompactActionButton(title: "Add Music", systemImage: "plus", action: action)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct iPhoneEmptyText: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("Missing")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("This item is no longer in the local library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.nwBackground)
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

private extension Color {
    static let nwBackground = NightwingTheme.background
    static let nwAccent = NightwingTheme.action
    static let nwDeepBlue = Color(red: 8 / 255, green: 60 / 255, blue: 130 / 255)
    static let nwViolet = Color(red: 62 / 255, green: 44 / 255, blue: 162 / 255)
    static let nwNeonPink = Color(red: 236 / 255, green: 36 / 255, blue: 143 / 255)
    static let nwSurfaceRaised = Color(red: 12 / 255, green: 24 / 255, blue: 45 / 255)
    static let nwHeaderTop = Color(red: 8 / 255, green: 54 / 255, blue: 104 / 255)
    static let nwHeaderMid = Color(red: 4 / 255, green: 18 / 255, blue: 42 / 255)
}

struct iPhoneRootView_Previews: PreviewProvider {
    static var previews: some View {
        iPhoneRootView()
    }
}
