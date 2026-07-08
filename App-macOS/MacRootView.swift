import SwiftUI
import UniformTypeIdentifiers

struct MacRootView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @State private var selection: MacSidebarSelection = .home
    @State private var searchText = ""
    @State private var showsQueue = true
    @State private var showsImporter = false
    @State private var selectedTrackID: Track.ID?

    var body: some View {
        ZStack {
            NightwingTheme.appBackground

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SpotifySidebarView(
                        selection: $selection,
                        showsImporter: $showsImporter
                    )

                    SpotifyContentView(
                        selection: $selection,
                        selectedTrackID: $selectedTrackID,
                        searchText: $searchText,
                        showsQueue: $showsQueue,
                        showsImporter: $showsImporter
                    )

                    if showsQueue {
                        SpotifyQueuePane()
                            .frame(width: 320)
                    }
                }
                .padding(8)

                MiniPlayerBar(showsQueue: $showsQueue)
                    .frame(height: 88)
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                appModel.importItems(urls)
            }
        }
        .preferredColorScheme(.dark)
        .tint(NightwingTheme.action)
    }
}

private enum MacSidebarSelection: Hashable {
    case home
    case album(LibraryAlbumGroup.ID)
    case playlists
    case playlist(Playlist.ID)
}

private struct SpotifySidebarView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @Binding var selection: MacSidebarSelection
    @Binding var showsImporter: Bool
    @State private var showsLibraryAlbums = true
    @State private var showsLibraryPlaylists = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nightwing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(NightwingTheme.primaryText)
                    .padding(.bottom, 4)

                SpotifySidebarButton(
                    title: "Home",
                    systemImage: "house.fill",
                    isSelected: selection == .home
                ) {
                    selection = .home
                }

                SpotifySidebarButton(
                    title: "Playlists",
                    systemImage: "music.note.list",
                    isSelected: selection == .playlists
                ) {
                    selection = .playlists
                }
            }
            .padding(14)
            .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your Library")
                        .font(.headline)
                        .foregroundStyle(NightwingTheme.primaryText)
                    Spacer()
                    Button {
                        showsImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .help("Add Files or Folders")
                }

                Divider()
                    .overlay(NightwingTheme.divider)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LibraryDisclosureHeader(
                            title: "Albums",
                            count: appModel.albumGroups.count,
                            isExpanded: $showsLibraryAlbums
                        )
                        .padding(.top, 4)

                        if showsLibraryAlbums {
                            if appModel.albumGroups.isEmpty {
                                Text("No albums yet")
                                    .font(.callout)
                                    .foregroundStyle(NightwingTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                            }
                            ForEach(appModel.albumGroups) { album in
                                SpotifyLibraryRow(
                                    title: album.title,
                                    subtitle: album.artistSummary,
                                    album: album,
                                    isSelected: selection == .album(album.id),
                                    doubleClickAction: {
                                        appModel.playAlbum(album)
                                    }
                                ) {
                                    selection = .album(album.id)
                                }
                            }
                        }

                        LibraryDisclosureHeader(
                            title: "Playlists",
                            count: appModel.library.playlists.count,
                            isExpanded: $showsLibraryPlaylists
                        )
                        .padding(.top, 12)

                        if showsLibraryPlaylists {
                            if appModel.library.playlists.isEmpty {
                                Text("No playlists yet")
                                    .font(.callout)
                                    .foregroundStyle(NightwingTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                            }
                            ForEach(appModel.library.playlists) { playlist in
                                SpotifyLibraryRow(
                                    title: playlist.name,
                                    subtitle: "\(playlist.items.count) track\(playlist.items.count == 1 ? "" : "s")",
                                    isSelected: selection == .playlist(playlist.id),
                                    doubleClickAction: {
                                        appModel.playPlaylist(playlist)
                                    }
                                ) {
                                    selection = .playlist(playlist.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(width: 280)
    }
}

private struct SpotifyContentView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @Binding var selection: MacSidebarSelection
    @Binding var selectedTrackID: Track.ID?
    @Binding var searchText: String
    @Binding var showsQueue: Bool
    @Binding var showsImporter: Bool

    var body: some View {
        VStack(spacing: 0) {
            SpotifyTopBar(
                searchText: $searchText,
                showsImporter: $showsImporter
            )

            Group {
                switch selection {
                case .home:
                    SpotifyHomeView(selection: $selection, searchText: $searchText)
                case .album(let albumID):
                    if let album = appModel.albumGroup(id: albumID) {
                        SpotifyAlbumDetailView(album: album, selectedTrackID: $selectedTrackID)
                    } else {
                        SpotifyHomeView(selection: $selection, searchText: $searchText)
                    }
                case .playlists:
                    SpotifyPlaylistsView(selection: $selection)
                case .playlist(let playlistID):
                    if let playlist = appModel.playlist(id: playlistID) {
                        SpotifyPlaylistDetailView(
                            selection: $selection,
                            playlist: playlist,
                            selectedTrackID: $selectedTrackID
                        )
                    } else {
                        SpotifyPlaylistsView(selection: $selection)
                    }
                }
            }
        }
        .background(NightwingTheme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipped()
    }
}

private struct SpotifyTopBar: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @Binding var searchText: String
    @Binding var showsImporter: Bool
    @AppStorage("nightwing.recentSearches") private var recentSearchesData = ""
    @State private var showsDownloads = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(NightwingTheme.secondaryText)
                TextField("Search albums or songs", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(NightwingTheme.primaryText)
                    .focused($isSearchFocused)
                    .onSubmit {
                        RecentSearches.add(searchText, to: &recentSearchesData)
                    }
            }
            .padding(.horizontal, 14)
            .frame(width: 320, height: 38)
            .nightwingGlass(Capsule(), isElevated: true)

            Spacer()

            Button {
                isSearchFocused = true
            } label: {
                EmptyView()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            if !activeDownloads.isEmpty {
                Button {
                    showsDownloads.toggle()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NightwingTheme.action)
                .nightwingGlass(Circle(), isElevated: true)
                .help("Downloads")
                .popover(isPresented: $showsDownloads, arrowEdge: .bottom) {
                    OnlineDownloadPopover(items: activeDownloads)
                }
            }

            Button {
                showsImporter = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NightwingTheme.primaryText)
            .nightwingGlass(Circle(), isElevated: true)
            .help("Add Files or Folders")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var activeDownloads: [OnlineDownloadDisplayItem] {
        let tracks = appModel.onlineSearchResults.compactMap { result -> OnlineDownloadDisplayItem? in
            guard case let .downloading(progress) = result.downloadState else { return nil }
            return OnlineDownloadDisplayItem(title: result.title, subtitle: result.artist ?? "Song", progress: progress)
        }
        let albums = appModel.onlineAlbumResults.compactMap { album -> OnlineDownloadDisplayItem? in
            guard case let .downloading(progress) = album.downloadState else { return nil }
            return OnlineDownloadDisplayItem(title: album.title, subtitle: album.artist ?? "Album", progress: progress)
        }
        return tracks + albums
    }
}

private struct OnlineDownloadDisplayItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let progress: Double
}

private struct OnlineDownloadPopover: View {
    let items: [OnlineDownloadDisplayItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preparing")
                .font(.headline)
                .foregroundStyle(NightwingTheme.primaryText)

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(NightwingTheme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(NightwingTheme.secondaryText)
                    }

                    ProgressView(value: item.progress)
                        .tint(NightwingTheme.action)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(NightwingTheme.panel)
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    case playlists = "Playlists"
    case online = "Online"

    var id: String { rawValue }
}

private enum RecentSearches {
    private static let separator = "\n"

    static func values(from data: String) -> [String] {
        data
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func add(_ query: String, to data: inout String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return }

        var values = values(from: data)
        values.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        values.insert(trimmed, at: 0)
        data = values.prefix(8).joined(separator: separator)
    }
}

private struct SpotifyHomeView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @Binding var selection: MacSidebarSelection
    @Binding var searchText: String
    @State private var showsAlbums = true
    @State private var searchScope: SearchScope = .all
    @AppStorage("nightwing.recentSearches") private var recentSearchesData = ""

    private var albums: [LibraryAlbumGroup] {
        appModel.filteredAlbumGroups(matching: searchText)
    }

    private var tracks: [Track] {
        appModel.filteredTracks(matching: searchText)
    }

    private var playlists: [Playlist] {
        let query = trimmedSearchText.lowercased()
        guard !query.isEmpty else { return appModel.library.playlists }
        return appModel.library.playlists.filter { playlist in
            playlist.name.lowercased().contains(query)
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 18)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Music")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(NightwingTheme.primaryText)

                    Text("\(appModel.library.tracks.count) local track\(appModel.library.tracks.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(NightwingTheme.secondaryText)
                }

                if trimmedSearchText.isEmpty {
                    RecentSearchesView(recentSearches: RecentSearches.values(from: recentSearchesData)) { query in
                        searchText = query
                    }

                    if appModel.albumGroups.isEmpty {
                        SpotifyEmptyImportView()
                    } else {
                        if !appModel.recentlyAddedTracks.isEmpty {
                            SearchSection(title: "Recently Added", count: appModel.recentlyAddedTracks.count) {
                                VStack(spacing: 4) {
                                    ForEach(appModel.recentlyAddedTracks.prefix(5)) { track in
                                        SearchLocalTrackRow(track: track)
                                    }
                                }
                            }
                        }

                        if !appModel.onlineDownloadedTracks.isEmpty {
                            SearchSection(title: "Online Downloads", count: appModel.onlineDownloadedTracks.count) {
                                VStack(spacing: 4) {
                                    ForEach(appModel.onlineDownloadedTracks.prefix(5)) { track in
                                        SearchLocalTrackRow(track: track)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            SectionDisclosureTitle(
                                title: "Albums",
                                count: albums.count,
                                isExpanded: $showsAlbums
                            )

                            if showsAlbums {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                    ForEach(albums) { album in
                                        SpotifyAlbumCard(album: album) {
                                            selection = .album(album.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    SpotifyUnifiedSearchView(
                        selection: $selection,
                        scope: $searchScope,
                        query: trimmedSearchText,
                        tracks: tracks,
                        albums: albums,
                        playlists: playlists
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .onAppear {
            updateOnlineSearch()
        }
        .onChange(of: searchText) { _, _ in
            updateOnlineSearch()
        }
    }

    private func updateOnlineSearch() {
        if !trimmedSearchText.isEmpty {
            appModel.searchOnline(query: trimmedSearchText)
        } else {
            appModel.clearOnlineSearchResults()
        }
    }
}

private enum SearchTopHit {
    case track(Track)
    case album(LibraryAlbumGroup)
    case playlist(Playlist)
    case onlineTrack(OnlineSearchResult)
    case onlineAlbum(OnlineAlbumSearchResult)
}

private struct RecentSearchesView: View {
    let recentSearches: [String]
    let select: (String) -> Void

    var body: some View {
        if !recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent Searches")
                    .font(.headline)
                    .foregroundStyle(NightwingTheme.primaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentSearches, id: \.self) { query in
                            Button {
                                select(query)
                            } label: {
                                Label(query, systemImage: "clock")
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(NightwingTheme.panel, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(NightwingTheme.primaryText)
                        }
                    }
                }
            }
        }
    }
}

private struct SpotifyUnifiedSearchView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @Binding var selection: MacSidebarSelection
    @Binding var scope: SearchScope
    let query: String
    let tracks: [Track]
    let albums: [LibraryAlbumGroup]
    let playlists: [Playlist]

    private var topHit: SearchTopHit? {
        if let track = tracks.first { return .track(track) }
        if let album = albums.first { return .album(album) }
        if let playlist = playlists.first { return .playlist(playlist) }
        if let onlineTrack = appModel.onlineSearchResults.first { return .onlineTrack(onlineTrack) }
        if let onlineAlbum = appModel.onlineAlbumResults.first { return .onlineAlbum(onlineAlbum) }
        return nil
    }

    private var showsSongs: Bool { scope == .all || scope == .songs }
    private var showsAlbums: Bool { scope == .all || scope == .albums }
    private var showsPlaylists: Bool { scope == .all || scope == .playlists }
    private var showsOnline: Bool { scope == .all || scope == .online }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SearchScopePicker(scope: $scope)

            if let topHit, scope == .all {
                SearchTopResultCard(topHit: topHit, selection: $selection)
            }

            if showsSongs && !tracks.isEmpty {
                SearchSection(title: "Songs", count: tracks.count) {
                    VStack(spacing: 4) {
                        ForEach(tracks.prefix(scope == .songs ? 50 : 5)) { track in
                            SearchLocalTrackRow(track: track)
                        }
                    }
                }
            }

            if showsAlbums && !albums.isEmpty {
                SearchSection(title: "Albums", count: albums.count) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(albums.prefix(scope == .albums ? 50 : 6)) { album in
                            SpotifyAlbumCard(album: album) {
                                selection = .album(album.id)
                            }
                        }
                    }
                }
            }

            if showsPlaylists && !playlists.isEmpty {
                SearchSection(title: "Playlists", count: playlists.count) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(playlists.prefix(scope == .playlists ? 50 : 6)) { playlist in
                            SpotifyPlaylistCard(playlist: playlist) {
                                selection = .playlist(playlist.id)
                            }
                        }
                    }
                }
            }

            if showsOnline {
                SpotifyOnlineResultsSection()
            }

            if tracks.isEmpty,
               albums.isEmpty,
               playlists.isEmpty,
               appModel.onlineSearchResults.isEmpty,
               appModel.onlineAlbumResults.isEmpty,
               !appModel.isSearchingOnline {
                SearchSuggestionView(query: query)
            }
        }
    }
}

private struct SearchScopePicker: View {
    @Binding var scope: SearchScope

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SearchScope.allCases) { candidate in
                Button {
                    scope = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(scope == candidate ? NightwingTheme.action : NightwingTheme.panel, in: Capsule())
                        .foregroundStyle(scope == candidate ? .black : NightwingTheme.primaryText)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SearchSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(NightwingTheme.primaryText)
                Text("\(count)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NightwingTheme.secondaryText)
            }
            content
        }
    }
}

private struct SearchTopResultCard: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let topHit: SearchTopHit
    @Binding var selection: MacSidebarSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Result")
                .font(.title2.weight(.bold))
                .foregroundStyle(NightwingTheme.primaryText)

            HStack(spacing: 14) {
                artwork
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(NightwingTheme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                SpotifyRoundPlayButton {
                    play()
                }
            }
            .padding(14)
            .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture(count: 2) {
                play()
            }
            .contextMenu {
                Button("Play", systemImage: "play.fill", action: play)
                menuActions
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        switch topHit {
        case let .track(track):
            NightwingArtworkView(track: track, size: 74, cornerRadius: 6)
        case let .album(album):
            NightwingArtworkView(album: album, size: 74, cornerRadius: 6)
        case .playlist:
            NightwingArtworkPlaceholder(size: 74, cornerRadius: 6, systemImage: "music.note.list")
        case let .onlineTrack(result):
            AsyncImage(url: result.thumbnailURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    NightwingArtworkPlaceholder(size: 74, cornerRadius: 6, systemImage: "play.rectangle")
                }
            }
        case let .onlineAlbum(album):
            AsyncImage(url: album.thumbnailURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    NightwingArtworkPlaceholder(size: 74, cornerRadius: 6, systemImage: "rectangle.stack")
                }
            }
        }
    }

    private var title: String {
        switch topHit {
        case let .track(track): return track.title
        case let .album(album): return album.title
        case let .playlist(playlist): return playlist.name
        case let .onlineTrack(result): return result.title
        case let .onlineAlbum(album): return album.title
        }
    }

    private var subtitle: String {
        switch topHit {
        case let .track(track): return "\(track.displayArtist) - Song"
        case let .album(album): return "\(album.artistSummary) - Album"
        case let .playlist(playlist): return "\(playlist.items.count) track\(playlist.items.count == 1 ? "" : "s") - Playlist"
        case let .onlineTrack(result): return "\(result.artist ?? "Unknown Artist") - Song"
        case let .onlineAlbum(album): return "\(album.artist ?? "Unknown Artist") - Album"
        }
    }

    @ViewBuilder
    private var menuActions: some View {
        switch topHit {
        case let .track(track):
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { appModel.playNext(track) }
            Button("Add to Queue", systemImage: "text.badge.plus") { appModel.enqueue(track) }
        case let .album(album):
            Button("Open Album", systemImage: "rectangle.stack") { selection = .album(album.id) }
        case let .playlist(playlist):
            Button("Open Playlist", systemImage: "music.note.list") { selection = .playlist(playlist.id) }
        case let .onlineTrack(result):
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { appModel.playNextOnlineTrack(result) }
            Button("Add to Queue", systemImage: "text.badge.plus") { appModel.enqueueOnlineTrack(result) }
            Button("Download", systemImage: "arrow.down.circle") { appModel.downloadOnlineTrack(result) }
        case let .onlineAlbum(album):
            Button("Download Album", systemImage: "arrow.down.circle") { appModel.downloadOnlineAlbum(album) }
        }
    }

    private func play() {
        switch topHit {
        case let .track(track):
            appModel.play(track)
        case let .album(album):
            appModel.playAlbum(album)
        case let .playlist(playlist):
            appModel.playPlaylist(playlist)
        case let .onlineTrack(result):
            appModel.playOnlineTrack(result)
        case let .onlineAlbum(album):
            appModel.downloadOnlineAlbum(album)
        }
    }
}

private struct SearchLocalTrackRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let track: Track
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isHovering {
                    Button {
                        appModel.play(track)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .frame(width: 34, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NightwingTheme.primaryText)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .frame(width: 34, height: 28)
                }
            }

            NightwingArtworkView(track: track, size: 46, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NightwingTheme.primaryText)
                    .lineLimit(1)
                Text("\(track.displayArtist) - \(track.displayAlbum)")
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(formattedDuration(track.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(NightwingTheme.secondaryText)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? NightwingTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(count: 2) {
            appModel.play(track)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play", systemImage: "play.fill") { appModel.play(track) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { appModel.playNext(track) }
            Button("Add to Queue", systemImage: "text.badge.plus") { appModel.enqueue(track) }
            if !appModel.library.playlists.isEmpty {
                Menu("Add to Playlist", systemImage: "music.note.list") {
                    ForEach(appModel.library.playlists) { playlist in
                        Button(playlist.name) {
                            appModel.add(track, to: playlist)
                        }
                    }
                }
            }
            if appModel.isOnlineDownloadedTrack(track) {
                Divider()
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    appModel.deleteOnlineDownloadedTrack(track)
                }
            }
        }
    }
}

private struct SearchSuggestionView: View {
    let query: String

    var body: some View {
        PlaceholderStateView(
            title: "No Results Yet",
            systemImage: "magnifyingglass",
            message: "Online results will appear here when YouTube Music returns matches for \(query)."
        )
        .frame(minHeight: 220)
    }
}

private struct SpotifyOnlineResultsSection: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !appModel.onlineAlbumResults.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Albums")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(NightwingTheme.primaryText)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 190), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(appModel.onlineAlbumResults) { album in
                            SpotifyOnlineAlbumCard(album: album)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Text("Songs")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(NightwingTheme.primaryText)

                if appModel.isSearchingOnline {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(NightwingTheme.action)
                }
            }

            if appModel.onlineSearchResults.isEmpty && appModel.onlineAlbumResults.isEmpty && appModel.isSearchingOnline {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(NightwingTheme.action)
                    Text("Searching")
                        .font(.callout)
                        .foregroundStyle(NightwingTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if appModel.onlineSearchResults.isEmpty && appModel.onlineAlbumResults.isEmpty {
                PlaceholderStateView(
                    title: "No Songs Found",
                    systemImage: "network",
                    message: "Try a different artist, song, or album name."
                )
                .frame(minHeight: 180)
            } else if !appModel.onlineSearchResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(appModel.onlineSearchResults) { result in
                        SpotifyOnlineResultRow(result: result)
                    }
                }
            }
        }
    }
}

private struct SectionDisclosureTitle: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(NightwingTheme.secondaryText)
            .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")

            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(NightwingTheme.primaryText)

            Text("\(count)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(NightwingTheme.secondaryText)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

private struct SpotifyOnlineAlbumCard: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let album: OnlineAlbumSearchResult
    @State private var isHovering = false
    @State private var confirmsDownload = false

    private var isDownloading: Bool {
        if case .downloading = album.downloadState {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { proxy in
                    AsyncImage(url: album.thumbnailURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            NightwingArtworkPlaceholder(size: proxy.size.width, cornerRadius: 6, systemImage: "rectangle.stack")
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .clipped()
                }
                .aspectRatio(1, contentMode: .fill)

                if isHovering || isDownloading {
                    Button {
                        confirmsDownload = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(NightwingTheme.action)
                                .frame(width: 42, height: 42)

                            if isDownloading {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.black)
                            } else {
                                Image(systemName: completedFolderURL == nil ? "arrow.down" : "checkmark")
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(.black)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading || completedFolderURL != nil)
                    .padding(10)
                    .accessibilityLabel("Download \(album.title)")
                }
            }

            Text(album.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(NightwingTheme.primaryText)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(NightwingTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(isHovering ? NightwingTheme.rowHover : NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            if completedFolderURL == nil {
                Button("Download Album", systemImage: "arrow.down.circle") {
                    confirmsDownload = true
                }
                .disabled(isDownloading)
            }
        }
        .confirmationDialog(
            "Download \(album.title)?",
            isPresented: $confirmsDownload,
            titleVisibility: .visible
        ) {
            Button("Download Album") {
                appModel.downloadOnlineAlbum(album)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The album will be saved under Online Downloads and imported into your library.")
        }
    }

    private var subtitle: String {
        [album.artist, album.detailText]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " - ")
    }

    private var completedFolderURL: URL? {
        if case let .completed(folderURL) = album.downloadState {
            return folderURL
        }
        return nil
    }
}

private struct SpotifyOnlineResultRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let result: OnlineSearchResult
    @State private var isHovering = false

    private var durationText: String {
        formattedDuration(result.duration)
    }

    private var isPreparing: Bool {
        if case .downloading = result.downloadState {
            return true
        }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isPreparing {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(NightwingTheme.action)
                } else if isHovering {
                    Button {
                        appModel.playOnlineTrack(result)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(NightwingTheme.primaryText)
                            .frame(width: 34, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(result.title)")
                } else {
                    Image(systemName: completedFileURL == nil ? "music.note" : "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(completedFileURL == nil ? NightwingTheme.secondaryText : NightwingTheme.action)
                }
            }
            .frame(width: 34)

            AsyncImage(url: result.thumbnailURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    NightwingArtworkPlaceholder(size: 54, cornerRadius: 6, systemImage: "play.rectangle")
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(result.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NightwingTheme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(result.artist ?? "Unknown Artist")
                        .lineLimit(1)

                    if isPreparing {
                        preparationText
                    }
                }
                .font(.caption)
                .foregroundStyle(NightwingTheme.secondaryText)
            }

            Spacer(minLength: 12)

            Text(durationText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(NightwingTheme.secondaryText)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? NightwingTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(count: 2) {
            appModel.playOnlineTrack(result)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play", systemImage: "play.fill") {
                appModel.playOnlineTrack(result)
            }

            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                appModel.playNextOnlineTrack(result)
            }
            .disabled(isPreparing)

            Button("Add to Queue", systemImage: "text.badge.plus") {
                appModel.enqueueOnlineTrack(result)
            }
            .disabled(isPreparing)

            if completedFileURL == nil {
                Button("Download", systemImage: "arrow.down.circle") {
                    appModel.downloadOnlineTrack(result)
                }
                .disabled(isPreparing)
            } else {
                Divider()
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    appModel.deleteOnlineTrack(result)
                }
            }
        }
    }

    @ViewBuilder
    private var preparationText: some View {
        switch result.downloadState {
        case let .downloading(progress):
            Text("Preparing \(Int(progress * 100))%")

        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)

        case .completed:
            Text("In Library")

        case .idle:
            EmptyView()
        }
    }

    private var completedFileURL: URL? {
        if case let .completed(fileURL) = result.downloadState {
            return fileURL
        }
        return nil
    }
}

private struct SpotifyAlbumDetailView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    let album: LibraryAlbumGroup
    @Binding var selectedTrackID: Track.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SpotifyCollectionHeader(
                    title: album.title,
                    subtitle: album.artistSummary,
                    detail: "\(album.trackCountText) - \(album.durationText(playbackRate: player.state.playbackDisplayRate))",
                    systemImage: "rectangle.stack",
                    album: album
                )

                HStack(spacing: 16) {
                    SpotifyRoundPlayButton {
                        appModel.playAlbum(album)
                    }

                    Text(album.trackCountText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(NightwingTheme.secondaryText)
                }

                SpotifyTrackHeader()

                VStack(spacing: 2) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        SpotifyTrackRow(
                            index: index + 1,
                            track: track,
                            contextTracks: album.tracks,
                            selectedTrackID: $selectedTrackID,
                            preloadLookaheadCount: album.tracks.count
                        )
                    }
                }
            }
            .padding(28)
        }
    }
}

private struct SpotifyPlaylistsView: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    @Binding var selection: MacSidebarSelection
    @State private var showsCreateSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Playlists")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(NightwingTheme.primaryText)

                    Spacer()

                    Button {
                        showsCreateSheet = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(NightwingTheme.action, in: Capsule())
                }

                if appModel.library.playlists.isEmpty {
                    PlaceholderStateView(
                        title: "No Playlists Yet",
                        systemImage: "music.note.list",
                        message: "Playlists will live here once you create them."
                    )
                    .frame(minHeight: 360)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 18)], spacing: 18) {
                        ForEach(appModel.library.playlists) { playlist in
                            SpotifyPlaylistCard(playlist: playlist) {
                                selection = .playlist(playlist.id)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $showsCreateSheet) {
            PlaylistNameSheet(title: "New Playlist", actionTitle: "Create") { name in
                let playlistID = appModel.createPlaylist(named: name)
                selection = .playlist(playlistID)
            }
        }
    }
}

private struct SpotifyPlaylistDetailView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    @Binding var selection: MacSidebarSelection
    let playlist: Playlist
    @Binding var selectedTrackID: Track.ID?

    @State private var showsRenameSheet = false
    @State private var draggedPlaylistItemID: PlaylistItem.ID?

    private var entries: [PlaylistTrackEntry] {
        appModel.playlistTrackEntries(for: playlist)
    }

    private var tracks: [Track] {
        entries.map(\.track)
    }

    private var durationText: String {
        formattedSpeedAdjustedDuration(
            tracks.compactMap(\.duration).reduce(0, +),
            playbackRate: player.state.playbackDisplayRate
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SpotifyCollectionHeader(
                    title: playlist.name,
                    subtitle: "Playlist",
                    detail: "\(tracks.count) track\(tracks.count == 1 ? "" : "s") - \(durationText)",
                    systemImage: "music.note.list"
                )

                HStack(spacing: 16) {
                    if !tracks.isEmpty {
                        SpotifyRoundPlayButton {
                            appModel.playPlaylist(playlist)
                        }
                    }

                    Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(NightwingTheme.secondaryText)

                    Spacer()

                    Button {
                        showsRenameSheet = true
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .help("Rename Playlist")

                    Button(role: .destructive) {
                        appModel.deletePlaylist(id: playlist.id)
                        selection = .playlists
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .help("Delete Playlist")
                }

                if !tracks.isEmpty {
                    HStack(spacing: 16) {
                        Text("Double-click a song to play it, or drag the handle to reorder.")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(NightwingTheme.secondaryText)
                    }
                }

                if tracks.isEmpty {
                    PlaceholderStateView(
                        title: "Empty Playlist",
                        systemImage: "music.note.list",
                        message: "Add tracks to this playlist to play them here."
                    )
                    .frame(minHeight: 280)
                } else {
                    SpotifyTrackHeader()

                    VStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            SpotifyTrackRow(
                                index: index + 1,
                                track: entry.track,
                                contextTracks: tracks,
                                selectedTrackID: $selectedTrackID,
                                showsDragHandle: true,
                                removeAction: {
                                    appModel.removePlaylistItem(entry.item, from: playlist)
                                }
                            )
                            .onDrag {
                                draggedPlaylistItemID = entry.item.id
                                return NSItemProvider(object: entry.item.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: PlaylistItemDropDelegate(
                                    targetIndex: index,
                                    draggedPlaylistItemID: $draggedPlaylistItemID,
                                    playlist: playlist,
                                    appModel: appModel
                                )
                            )
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $showsRenameSheet) {
            PlaylistNameSheet(title: "Rename Playlist", initialName: playlist.name, actionTitle: "Rename") { name in
                appModel.renamePlaylist(id: playlist.id, to: name)
            }
        }
    }
}

private struct SpotifyQueuePane: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    @State private var draggedQueueItemID: PlaybackQueueItem.ID?

    private var queueItems: [PlaybackQueueItem] {
        player.state.queue.items
    }

    private var currentIndex: Int? {
        player.state.queue.currentIndex
    }

    private var currentItem: PlaybackQueueItem? {
        player.state.queue.currentItem
    }

    private var upcomingItems: [(offset: Int, element: PlaybackQueueItem)] {
        guard let currentIndex else {
            return Array(queueItems.enumerated())
        }

        return Array(queueItems.enumerated()).filter { $0.offset > currentIndex }
    }

    private var earlierItems: [(offset: Int, element: PlaybackQueueItem)] {
        guard let currentIndex else { return [] }
        return Array(queueItems.enumerated()).filter { $0.offset < currentIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if queueItems.isEmpty {
                Spacer()
                PlaceholderStateView(
                    title: "Queue Empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    message: "Tracks you play or add next will appear here."
                )
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let currentItem {
                            queueSection(title: "Now Playing") {
                                QueueItemRow(
                                    item: currentItem,
                                    index: currentIndex ?? 0,
                                    isCurrent: true,
                                    showsDragHandle: false
                                )
                            }
                        }

                        queueSection(title: "Up Next") {
                            if upcomingItems.isEmpty {
                                Text("The queue loops back to the start after this album or playlist finishes.")
                                    .font(.caption)
                                    .foregroundStyle(NightwingTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(upcomingItems, id: \.element.id) { index, item in
                                    QueueItemRow(
                                        item: item,
                                        index: index,
                                        isCurrent: false,
                                        showsDragHandle: true
                                    )
                                    .onDrag {
                                        draggedQueueItemID = item.id
                                        return NSItemProvider(object: item.id.uuidString as NSString)
                                    }
                                    .onDrop(
                                        of: [.text],
                                        delegate: QueueItemDropDelegate(
                                            targetIndex: index,
                                            draggedQueueItemID: $draggedQueueItemID,
                                            player: player
                                        )
                                    )
                                }
                            }
                        }

                        if !earlierItems.isEmpty {
                            queueSection(title: "Earlier") {
                                ForEach(earlierItems, id: \.element.id) { index, item in
                                    QueueItemRow(
                                        item: item,
                                        index: index,
                                        isCurrent: false,
                                        showsDragHandle: false
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Queue")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(NightwingTheme.primaryText)

                Text("\(queueItems.count) track\(queueItems.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
            }

            Spacer()

            Button {
                player.clearUpcomingQueue()
            } label: {
                Image(systemName: "text.badge.minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(upcomingItems.isEmpty ? NightwingTheme.secondaryText.opacity(0.5) : NightwingTheme.secondaryText)
            .disabled(upcomingItems.isEmpty)
            .help("Clear Up Next")
            .accessibilityLabel("Clear Up Next")
        }
    }

    private func queueSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(NightwingTheme.secondaryText)
                .padding(.horizontal, 8)

            VStack(spacing: 4) {
                content()
            }
        }
    }
}

private struct QueueItemRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    let item: PlaybackQueueItem
    let index: Int
    let isCurrent: Bool
    let showsDragHandle: Bool

    @State private var isHovering = false

    private var track: Track? {
        appModel.track(for: item)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                NightwingArtworkView(track: track, size: 42, cornerRadius: 6)

                if isHovering && !isCurrent {
                    Button {
                        try? player.playQueueItem(id: item.id)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(NightwingTheme.primaryText)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(title)")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? NightwingTheme.action : NightwingTheme.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isHovering {
                rowActions
            } else if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NightwingTheme.action)
                    .frame(width: 24)
            } else {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .frame(width: 24)
            }
        }
        .padding(8)
        .background(
            (isCurrent || isHovering) ? NightwingTheme.rowHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(count: 2) {
            try? player.playQueueItem(id: item.id)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play", systemImage: "play.fill") {
                try? player.playQueueItem(id: item.id)
            }
            Divider()
            Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                player.removeFromQueue(id: item.id)
            }
        }
    }

    private var rowActions: some View {
        HStack(spacing: 4) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .help("Drag to reorder")
                    .accessibilityLabel("Drag to reorder")
            }

            Button {
                player.removeFromQueue(id: item.id)
            } label: {
                Image(systemName: "minus.circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NightwingTheme.secondaryText)
            .help("Remove")
        }
        .foregroundStyle(NightwingTheme.secondaryText)
    }

    private var title: String {
        track?.title ?? item.title ?? item.url.deletingPathExtension().lastPathComponent
    }

    private var subtitle: String {
        if let track {
            return "\(track.displayArtist) - \(track.displayAlbum)"
        }

        return item.url.deletingLastPathComponent().lastPathComponent
    }
}

private struct QueueItemDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedQueueItemID: PlaybackQueueItem.ID?
    let player: PlayerEngine

    func dropEntered(info: DropInfo) {
        guard let draggedQueueItemID else { return }
        player.moveQueueItem(id: draggedQueueItemID, to: targetIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedQueueItemID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct SpotifyAlbumCard: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let album: LibraryAlbumGroup
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { proxy in
                    NightwingArtworkView(album: album, size: proxy.size.width, cornerRadius: 8)
                        .frame(width: proxy.size.width, height: proxy.size.width)
                        .clipped()
                }
                .aspectRatio(1, contentMode: .fit)

                Button {
                    appModel.playAlbum(album)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 46, height: 46)
                        .background(NightwingTheme.action, in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .offset(x: -10, y: -10)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(album.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NightwingTheme.primaryText)
                    .lineLimit(1)
                Text(album.artistSummary)
                    .font(.caption)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? NightwingTheme.panelElevated : NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2) {
            appModel.playAlbum(album)
        }
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
    }
}

private struct SpotifyPlaylistCard: View {
    let playlist: Playlist
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                NightwingArtworkPlaceholder(size: proxy.size.width, cornerRadius: 8, systemImage: "music.note.list")
                    .frame(width: proxy.size.width, height: proxy.size.width)
                    .clipped()
            }
            .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(NightwingTheme.primaryText)
                .lineLimit(1)

            Text("\(playlist.items.count) track\(playlist.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(NightwingTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(14)
        .background(isHovering ? NightwingTheme.panelElevated : NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
    }
}

private struct SpotifyCollectionHeader: View {
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    var album: LibraryAlbumGroup? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            if let album {
                NightwingArtworkView(album: album, size: 190, cornerRadius: 8, systemImage: systemImage)
            } else {
                NightwingArtworkPlaceholder(size: 190, cornerRadius: 8, systemImage: systemImage)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(NightwingTheme.secondaryText)

                Text(title)
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(NightwingTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)

                Text(detail)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NightwingTheme.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}

private struct SpotifyTrackHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Text("#")
                .frame(width: 34, alignment: .center)
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Album")
                .frame(width: 200, alignment: .leading)
            Color.clear
                .frame(width: 58)
            Image(systemName: "clock")
                .frame(width: 56, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(NightwingTheme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NightwingTheme.divider)
                .frame(height: 1)
        }
    }
}

private struct SpotifyTrackRow: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    let index: Int
    let track: Track
    let contextTracks: [Track]
    @Binding var selectedTrackID: Track.ID?
    var preloadLookaheadCount = 1
    var showsDragHandle = false
    var removeAction: (() -> Void)? = nil

    @State private var isHovering = false

    private var isCurrent: Bool {
        appModel.isCurrentTrack(track)
    }

    private var isStartingCurrentTrack: Bool {
        isCurrent && appModel.isPlaybackStarting
    }

    private var isSelected: Bool {
        selectedTrackID == track.id
    }

    private func selectTrack() {
        selectedTrackID = track.id
    }

    private func playTrack() {
        selectTrack()
        appModel.play(track, within: contextTracks, preloadLookaheadCount: preloadLookaheadCount)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if isHovering {
                    Button {
                        playTrack()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(NightwingTheme.primaryText)
                            .frame(width: 34, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(track.title)")
                } else if isCurrent && (player.state.isPlaying || isStartingCurrentTrack) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NightwingTheme.action)
                } else {
                    Text("\(index)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(NightwingTheme.secondaryText)
                }
            }
            .frame(width: 34)

            HStack(spacing: 12) {
                NightwingArtworkView(track: track, size: 40, cornerRadius: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.callout.weight((isCurrent || isSelected) ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? NightwingTheme.action : NightwingTheme.primaryText)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.caption)
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.displayAlbum)
                .font(.callout)
                .foregroundStyle(NightwingTheme.secondaryText)
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)

            if track.availability != .available {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(NightwingTheme.warning)
                    .frame(width: 24)
            }

            HStack(spacing: 4) {
                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .help("Drag to reorder")
                        .opacity(isHovering ? 1 : 0)
                } else {
                    Color.clear
                        .frame(width: 24, height: 24)
                }

                if let removeAction {
                    Button(action: removeAction) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isHovering)
                    .foregroundStyle(NightwingTheme.secondaryText)
                    .help("Remove from playlist")
                    .opacity(isHovering ? 1 : 0)
                } else {
                    Color.clear
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 58, alignment: .trailing)

            Text(formattedSpeedAdjustedDuration(track.duration, playbackRate: player.state.playbackDisplayRate))
                .font(.callout.monospacedDigit())
                .foregroundStyle(NightwingTheme.secondaryText)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((isSelected || isHovering) ? NightwingTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .simultaneousGesture(TapGesture(count: 1).onEnded(selectTrack))
        .onTapGesture(count: 2) {
            playTrack()
        }
        .onHover { isHovering = $0 }
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
            if let removeAction {
                Divider()
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                    removeAction()
                }
            }
            if appModel.isOnlineDownloadedTrack(track) {
                Divider()
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    appModel.deleteOnlineDownloadedTrack(track)
                }
            }
        }
    }
}

private struct PlaylistItemDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedPlaylistItemID: PlaylistItem.ID?
    let playlist: Playlist
    let appModel: NightwingAppModel

    func dropEntered(info: DropInfo) {
        guard let draggedPlaylistItemID else { return }
        appModel.movePlaylistItem(id: draggedPlaylistItemID, in: playlist, to: targetIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPlaylistItemID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct SpotifyArtworkView: View {
    let title: String
    let size: CGFloat
    let cornerRadius: CGFloat
    var systemImage = "music.note"

    var body: some View {
        NightwingArtworkPlaceholder(size: size, cornerRadius: cornerRadius, systemImage: systemImage)
    }
}

private struct SpotifyRoundPlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 58, height: 58)
                .background(NightwingTheme.action, in: Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
    }
}

private struct PlaylistNameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    var initialName = ""
    let actionTitle: String
    let onSubmit: (String) -> Void

    @State private var name: String = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(NightwingTheme.primaryText)

            TextField("Playlist name", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(NightwingTheme.rowHover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(NightwingTheme.primaryText)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(NightwingTheme.secondaryText)

                Button(actionTitle) {
                    submit()
                }
                .buttonStyle(.plain)
                .disabled(trimmedName.isEmpty)
                .foregroundStyle(trimmedName.isEmpty ? NightwingTheme.secondaryText : .black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(trimmedName.isEmpty ? NightwingTheme.rowHover : NightwingTheme.action, in: Capsule())
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(NightwingTheme.panel)
        .onAppear {
            name = initialName
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName)
        dismiss()
    }
}

private struct LibraryDisclosureHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)

                Text(title)
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NightwingTheme.secondaryText.opacity(0.8))
            }
            .foregroundStyle(NightwingTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

private struct SpotifySidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(isSelected ? NightwingTheme.primaryText : NightwingTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? NightwingTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SpotifyLibraryRow: View {
    let title: String
    let subtitle: String
    var album: LibraryAlbumGroup? = nil
    let isSelected: Bool
    var doubleClickAction: (() -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let album {
                    NightwingArtworkView(album: album, size: 42, cornerRadius: 5)
                } else {
                    NightwingArtworkPlaceholder(size: 42, cornerRadius: 5)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? NightwingTheme.action : NightwingTheme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(NightwingTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background((isSelected || isHovering) ? NightwingTheme.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                doubleClickAction?()
            }
        )
        .onHover { isHovering = $0 }
    }
}

private struct SpotifyEmptyImportView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start with a folder")
                .font(.title2.weight(.bold))
                .foregroundStyle(NightwingTheme.primaryText)
            Text("Import a folder of albums and they will appear here as playable cards.")
                .font(.callout)
                .foregroundStyle(NightwingTheme.secondaryText)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
        .background(NightwingTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SpotifyPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(NightwingTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                configuration.isPressed ? NightwingTheme.glassPressedTint : NightwingTheme.glassElevatedTint,
                in: Capsule()
            )
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(NightwingTheme.glassStroke, lineWidth: 1)
            }
    }
}

struct MacRootView_Previews: PreviewProvider {
    static var previews: some View {
        MacRootView()
    }
}
