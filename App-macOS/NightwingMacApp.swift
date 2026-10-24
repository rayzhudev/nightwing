import AppKit
import SwiftUI

@main
struct NightwingMacApp: App {
    @StateObject private var appModel = NightwingAppModel()

    init() {
        UserDefaults.standard.register(defaults: [
            "nightwing.restorePlaybackOnLaunch": true,
            "nightwing.automaticallyLookupSyncedLyrics": true,
            "nightwing.defaultVolume": 0.85,
            "nightwing.accentColor": NightwingAccent.blue.rawValue
        ])
        if UserDefaults.standard.string(forKey: "nightwing.accentColor") == "defaultAccent" {
            UserDefaults.standard.set(NightwingAccent.blue.rawValue, forKey: "nightwing.accentColor")
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environmentObject(appModel)
                .environmentObject(appModel.player)
        }
        .defaultSize(width: 1280, height: 800)
        Settings {
            NightwingSettingsView()
                .environmentObject(appModel)
                .environmentObject(appModel.player)
        }
        .commands {
            SidebarCommands()
            PlaybackCommands(appModel: appModel)
        }
    }
}

private struct NightwingSettingsView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @EnvironmentObject private var player: PlayerEngine

    @AppStorage("nightwing.restorePlaybackOnLaunch") private var restoresPlaybackOnLaunch = true
    @AppStorage("nightwing.automaticallyLookupSyncedLyrics") private var automaticallyLookupSyncedLyrics = true
    @AppStorage("nightwing.defaultVolume") private var defaultVolume = 0.85
    @AppStorage("nightwing.recentSearches") private var recentSearchesData = ""
    @AppStorage("nightwing.accentColor") private var accentColor = NightwingAccent.blue.rawValue

    var body: some View {
        TabView {
            Form {
                Section("Theme") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 14) {
                            Text("Colour")
                                .padding(.top, 7)
                                .frame(width: 56, alignment: .leading)

                            HStack(spacing: 4) {
                                ForEach(NightwingAccent.allCases) { option in
                                    AccentChoiceButton(option: option, selection: $accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                Section("Startup") {
                    Toggle("Restore the previous queue when Nightwing opens", isOn: $restoresPlaybackOnLaunch)
                    Text("Playback resumes at the last saved position. Turn this off to always open with a fresh queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Search") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recent searches")
                            Text(recentSearchesData.isEmpty ? "No searches saved" : "Shown while the search field is empty")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clear") { recentSearchesData = "" }
                            .disabled(recentSearchesData.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Listening") {
                    HStack {
                        Text("Default volume")
                        Slider(value: volumeBinding, in: 0...1)
                        Text(defaultVolume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    Text("Applied now and used the next time Nightwing opens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Lyrics") {
                    Toggle("Automatically look up synced lyrics", isOn: $automaticallyLookupSyncedLyrics)
                    Text("Nightwing first uses lyrics saved for the track, then checks for synced lyrics online when this is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Lyrics model") {
                        lyricsModelStatus
                    }

                    if case .failed(let message) = appModel.lyricsModelState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    Text("\(appModel.lyricsModelDisplayName) creates lyrics privately on your Mac. Download size: about \(appModel.lyricsModelSizeText).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let progress = appModel.lyricsLibraryGenerationProgress {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Creating lyrics for your library")
                                Spacer()
                                Text("\(progress.completed) of \(progress.total)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            if let title = progress.currentTrackTitle {
                                Text("Working on \(title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("Playback", systemImage: "play.circle") }

            Form {
                Section("Library") {
                    LabeledContent("Watched folders") {
                        Text("Refresh automatically every 30 seconds")
                            .foregroundStyle(.secondary)
                    }
                    Text("Use the + button in the library to add a folder. Nightwing keeps that folder in sync without copying your original music files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Online downloads") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download cache")
                            Text("Downloaded songs are kept locally and appear in your library.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal in Finder") { revealDownloadsFolder() }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("Library", systemImage: "music.note.list") }

            MusicServicesSettingsView(connections: appModel.musicServiceConnections)
                .environmentObject(appModel)
                .tabItem { Label("Connections", systemImage: "link") }
        }
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private var lyricsModelStatus: some View {
        switch appModel.lyricsModelState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking...").foregroundStyle(.secondary)
            }
        case .notDownloaded:
            Button("Download (\(appModel.lyricsModelSizeText))") {
                appModel.downloadLyricsModel()
            }
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(appModel.lyricsModelDownloadedSizeText(progress: progress)) of \(appModel.lyricsModelSizeText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .frame(width: 180)
            }
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Button("Try Download Again") {
                appModel.downloadLyricsModel()
            }
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { defaultVolume },
            set: { newValue in
                defaultVolume = newValue
                player.setVolume(newValue)
            }
        )
    }

    private func revealDownloadsFolder() {
        let directory = YtDlpDownloadService.downloadsBaseURL()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

}

private struct MusicServicesSettingsView: View {
    @EnvironmentObject private var appModel: NightwingAppModel
    @ObservedObject var connections: MusicServiceConnections

    @AppStorage(MusicServiceConnections.youtubeClientIDDefaultsKey) private var youtubeClientID = ""
    @AppStorage(MusicServiceConnections.spotifyClientIDDefaultsKey) private var spotifyClientID = ""
    @State private var youtubeClientSecret = MusicServiceConnections.savedClientSecret(for: .youtube)
    @State private var spotifyClientSecret = ""

    var body: some View {
        Form {
            MusicServiceAccountSection(
                service: .youtube,
                clientID: $youtubeClientID,
                clientSecret: $youtubeClientSecret,
                connections: connections
            )

            MusicServiceAccountSection(
                service: .spotify,
                clientID: $spotifyClientID,
                clientSecret: $spotifyClientSecret,
                connections: connections
            )

            Section("How imports work") {
                Text("Nightwing imports the playlist order and source links, then matches songs already in your local library. Unmatched songs stay visible as linked items; Spotify and YouTube audio is not copied by account import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MusicServiceAccountSection: View {
    @EnvironmentObject private var appModel: NightwingAppModel

    let service: MusicPlaylistService
    @Binding var clientID: String
    @Binding var clientSecret: String
    @ObservedObject var connections: MusicServiceConnections

    private var state: MusicServiceConnectionState {
        connections.state(for: service)
    }

    private var playlists: [RemoteMusicPlaylist] {
        connections.playlists(for: service)
    }

    var body: some View {
        Section(service.displayName) {
            LabeledContent("Status") {
                connectionStatus
            }

            if !state.isConnected {
                TextField("OAuth client ID", text: $clientID)
                    .textContentType(.none)

                if service == .youtube {
                    SecureField("OAuth client secret", text: $clientSecret)
                        .textContentType(.password)
                }

                Text(setupHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                if state.isConnected {
                    Button("Disconnect") {
                        Task { await connections.disconnect(service) }
                    }
                    Button("Refresh Playlists") {
                        Task { await connections.loadPlaylists(for: service) }
                    }
                    .disabled(connections.loadingServices.contains(service))
                } else {
                    Button("Connect \(service.displayName)") {
                        Task {
                            await connections.connect(
                                service,
                                clientID: clientID,
                                clientSecret: clientSecret
                            )
                        }
                    }
                    .disabled(
                        clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (service == .youtube && clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            || state == .connecting
                    )
                }

                if connections.loadingServices.contains(service) || state == .connecting {
                    ProgressView().controlSize(.small)
                }
            }

            if state.isConnected {
                if playlists.isEmpty && !connections.loadingServices.contains(service) {
                    Text("No importable playlists were returned for this account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(playlists) { playlist in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .lineLimit(1)
                                Text("\(playlist.itemCount) item\(playlist.itemCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if appModel.isImporting(playlist) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(appModel.hasImported(playlist) ? "Refresh Import" : "Import") {
                                    appModel.importRemotePlaylist(playlist)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: state.isConnected) {
            if state.isConnected && playlists.isEmpty {
                await connections.loadPlaylists(for: service)
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch state {
        case .disconnected:
            Text("Not connected").foregroundStyle(.secondary)
        case .connecting:
            Text("Signing in…").foregroundStyle(.secondary)
        case .connected(let accountName):
            Label(accountName ?? "Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    private var setupHelp: String {
        switch service {
        case .youtube:
            return "Use the client ID and client secret from a Google Cloud Desktop OAuth client, and enable YouTube Data API v3. The secret is stored in your Mac's Keychain. Nightwing requests read-only YouTube access."
        case .spotify:
            return "Use a Spotify app client ID and register http://127.0.0.1/callback as its redirect URI. Development Mode is limited by Spotify to approved users."
        }
    }
}

private struct AccentChoiceButton: View {
    let option: NightwingAccent
    @Binding var selection: String

    private var isSelected: Bool { selection == option.rawValue }

    var body: some View {
        Button {
            selection = option.rawValue
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(option.swatch)
                        .frame(width: 25, height: 25)

                    Circle()
                        .strokeBorder(isSelected ? Color.primary.opacity(0.55) : .clear, lineWidth: 2)
                        .padding(-3)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(option.usesLightCheckmark ? .white : .black)
                    }
                }

                Text(option.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(width: 48, height: 48, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PlaybackCommands: Commands {
    @ObservedObject var appModel: NightwingAppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(appModel.player.state.isPlaying ? "Pause" : "Play") {
                appModel.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Previous Track") {
                try? appModel.player.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])

            Button("Next Track") {
                try? appModel.player.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])

            Divider()

            Button("Volume Down") {
                appModel.player.adjustVolume(by: -0.05)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])

            Button("Volume Up") {
                appModel.player.adjustVolume(by: 0.05)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
        }
    }
}
