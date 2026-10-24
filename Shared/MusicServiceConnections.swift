import Foundation

public struct RemoteMusicPlaylist: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var service: MusicPlaylistService
    public var name: String
    public var ownerName: String?
    public var itemCount: Int
    public var artworkURL: URL?
    public var sourceURL: URL?

    public init(
        id: String,
        service: MusicPlaylistService,
        name: String,
        ownerName: String? = nil,
        itemCount: Int,
        artworkURL: URL? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.service = service
        self.name = name
        self.ownerName = ownerName
        self.itemCount = itemCount
        self.artworkURL = artworkURL
        self.sourceURL = sourceURL
    }
}

public struct RemoteMusicTrack: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var sourceURL: URL?
    public var artworkURL: URL?

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        sourceURL: URL? = nil,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sourceURL = sourceURL
        self.artworkURL = artworkURL
    }
}

enum PlaylistTrackMatcher {
    static func match(_ remoteTracks: [RemoteMusicTrack], in localTracks: [Track]) -> [ImportedPlaylistItem] {
        remoteTracks.map { remote in
            let match = bestMatch(for: remote, in: localTracks)
            return ImportedPlaylistItem(
                id: remote.id,
                title: remote.title,
                artist: remote.artist,
                album: remote.album,
                duration: remote.duration,
                sourceURL: remote.sourceURL,
                artworkURL: remote.artworkURL,
                matchedTrackID: match?.id
            )
        }
    }

    private static func bestMatch(for remote: RemoteMusicTrack, in localTracks: [Track]) -> Track? {
        let remoteTitle = normalized(remote.title)
        guard !remoteTitle.isEmpty else { return nil }
        let remoteArtist = normalized(remote.artist ?? "")
        let remoteAlbum = normalized(remote.album ?? "")

        let candidate = localTracks.lazy
            .map { track -> (track: Track, score: Double) in
                let localTitle = normalized(track.title)
                let localArtist = normalized(track.artist ?? "")
                let localAlbum = normalized(track.album ?? "")

                var score = similarity(remoteTitle, localTitle) * 0.72
                if !remoteArtist.isEmpty && !localArtist.isEmpty {
                    score += similarity(remoteArtist, localArtist) * 0.2
                }
                if !remoteAlbum.isEmpty && !localAlbum.isEmpty {
                    score += similarity(remoteAlbum, localAlbum) * 0.03
                }
                if let remoteDuration = remote.duration,
                   let localDuration = track.duration,
                   abs(remoteDuration - localDuration) <= 5 {
                    score += 0.05
                }
                return (track, score)
            }
            .max { $0.score < $1.score }

        guard let candidate, candidate.score >= 0.72 else { return nil }
        return candidate.track
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let withoutCommonVideoTags = folded.replacingOccurrences(
            of: #"\s*[\(\[]\s*(official\s+)?(music\s+)?(video|audio|visualizer|lyrics?|hd|4k)[^\)\]]*[\)\]]\s*"#,
            with: " ",
            options: .regularExpression
        )
        let cleaned = String(withoutCommonVideoTags.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " "
        })
        return cleaned
            .split(separator: " ")
            .map(String.init)
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 0.9 }

        let left = Set(lhs.split(separator: " "))
        let right = Set(rhs.split(separator: " "))
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(union.count)
    }
}

#if os(macOS)
import AppKit
import CryptoKit
import Network
import Security

enum MusicServiceConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(accountName: String?)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum MusicServiceConnectionError: LocalizedError {
    case missingClientID(MusicPlaylistService)
    case missingClientSecret(MusicPlaylistService)
    case unableToOpenBrowser
    case invalidOAuthCallback
    case stateMismatch
    case authorizationDenied(String)
    case missingRefreshToken
    case notConnected(MusicPlaylistService)
    case invalidResponse
    case secureRandomFailure
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID(let service):
            return "Add the \(service.displayName) client ID in Nightwing Settings first."
        case .missingClientSecret(let service):
            return "Add the \(service.displayName) client secret in Nightwing Settings first."
        case .unableToOpenBrowser:
            return "Nightwing could not open the sign-in page."
        case .invalidOAuthCallback:
            return "The sign-in response was incomplete. Please try again."
        case .stateMismatch:
            return "Nightwing rejected an unexpected sign-in response. Please try again."
        case .authorizationDenied(let message):
            return message
        case .missingRefreshToken:
            return "The saved sign-in has expired. Please connect the account again."
        case .notConnected(let service):
            return "Connect \(service.displayName) before importing a playlist."
        case .invalidResponse:
            return "The music service returned an unreadable response."
        case .secureRandomFailure:
            return "Nightwing could not create a secure sign-in request. Please try again."
        case .apiError(let status, let message):
            return message.isEmpty ? "The music service returned error \(status)." : message
        }
    }
}

@MainActor
final class MusicServiceConnections: ObservableObject {
    static let youtubeClientIDDefaultsKey = "nightwing.youtube.clientID"
    static let spotifyClientIDDefaultsKey = "nightwing.spotify.clientID"

    @Published private(set) var states: [MusicPlaylistService: MusicServiceConnectionState] = [
        .youtube: .disconnected,
        .spotify: .disconnected
    ]
    @Published private(set) var playlists: [MusicPlaylistService: [RemoteMusicPlaylist]] = [:]
    @Published private(set) var loadingServices: Set<MusicPlaylistService> = []

    @Published private(set) var playlistErrors: [MusicPlaylistService: String] = [:]
    private var tokens: [MusicPlaylistService: OAuthToken] = [:]
    private var generations: [MusicPlaylistService: UUID] = [:]
    private var requests: [MusicPlaylistService: [UUID: Task<(Data, URLResponse), Error>]] = [:]
    private var tokenRefreshes: [MusicPlaylistService: Task<OAuthToken, Error>] = [:]
    private var receivers: [MusicPlaylistService: LoopbackOAuthReceiver] = [:]
    private let session: URLSession
    private let saveToken: (OAuthToken, MusicPlaylistService) throws -> Void
    private let deleteToken: (MusicPlaylistService) -> Void

    private func generation(for service: MusicPlaylistService) -> UUID {
        if let value = generations[service] { return value }
        let value = UUID()
        generations[service] = value
        return value
    }

    @discardableResult
    private func invalidate(_ service: MusicPlaylistService) -> UUID {
        let value = UUID()
        generations[service] = value
        requests.removeValue(forKey: service)?.values.forEach { $0.cancel() }
        tokenRefreshes.removeValue(forKey: service)?.cancel()
        receivers.removeValue(forKey: service)?.cancel()
        loadingServices.remove(service)
        playlistErrors[service] = nil
        return value
    }

    private func serviceData(for request: URLRequest, service: MusicPlaylistService) async throws -> (Data, URLResponse) {
        let generation = generation(for: service)
        let id = UUID()
        let task = Task { try await session.data(for: request) }
        requests[service, default: [:]][id] = task
        defer { requests[service]?[id] = nil }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                guard generations[service] == generation else { throw CancellationError() }
                try Task.checkCancellation()
                return result
            } catch {
                guard generations[service] == generation, !Task.isCancelled else { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }

    static func savedClientSecret(for service: MusicPlaylistService) -> String {
        OAuthClientSecretStore.load(for: service) ?? ""
    }

    static func isConfigured(for service: MusicPlaylistService) -> Bool {
        let defaultsKey = service == .youtube ? youtubeClientIDDefaultsKey : spotifyClientIDDefaultsKey
        guard let clientID = UserDefaults.standard.string(forKey: defaultsKey),
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return service != .youtube || !savedClientSecret(for: service).isEmpty
    }

    init(
        session: URLSession = .shared,
        loadToken: (MusicPlaylistService) -> OAuthToken? = { OAuthTokenStore.load(for: $0) },
        saveToken: @escaping (OAuthToken, MusicPlaylistService) throws -> Void = { try OAuthTokenStore.save($0, for: $1) },
        deleteToken: @escaping (MusicPlaylistService) -> Void = { OAuthTokenStore.delete(for: $0) }
    ) {
        self.session = session
        self.saveToken = saveToken
        self.deleteToken = deleteToken
        for service in MusicPlaylistService.allCases {
            if let token = loadToken(service) {
                tokens[service] = token
                states[service] = .connected(accountName: nil)
            }
        }
    }

    func state(for service: MusicPlaylistService) -> MusicServiceConnectionState {
        states[service] ?? .disconnected
    }

    func playlists(for service: MusicPlaylistService) -> [RemoteMusicPlaylist] {
        playlists[service] ?? []
    }

    func connect(_ service: MusicPlaylistService, clientID: String, clientSecret: String = "") async {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            states[service] = .failed(MusicServiceConnectionError.missingClientID(service).localizedDescription)
            return
        }
        if service == .youtube, clientSecret.isEmpty {
            states[service] = .failed(MusicServiceConnectionError.missingClientSecret(service).localizedDescription)
            return
        }

        let generation = invalidate(service)
        states[service] = .connecting
        defer { if generations[service] == generation { receivers[service] = nil } }
        do {
            if service == .youtube {
                try OAuthClientSecretStore.save(clientSecret, for: service)
            }
            let receiver = try LoopbackOAuthReceiver()
            receivers[service] = receiver
            let redirectURL = try await receiver.start()
            guard generations[service] == generation else { throw CancellationError() }
            let verifier = try Self.randomURLSafeString(byteCount: 48)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
            let state = try Self.randomURLSafeString(byteCount: 24)
            let authorizationURL = try makeAuthorizationURL(
                service: service,
                clientID: clientID,
                redirectURL: redirectURL,
                challenge: challenge,
                state: state
            )

            guard NSWorkspace.shared.open(authorizationURL) else {
                throw MusicServiceConnectionError.unableToOpenBrowser
            }

            let callbackURL = try await receiver.waitForCallback()
            guard generations[service] == generation else { throw CancellationError() }
            guard callbackURL.host == "127.0.0.1", callbackURL.path == "/callback" else {
                throw MusicServiceConnectionError.invalidOAuthCallback
            }
            let parameters = Self.oauthParameters(from: callbackURL)
            guard parameters["state"] == state else { throw MusicServiceConnectionError.stateMismatch }
            if let error = parameters["error"] {
                throw MusicServiceConnectionError.authorizationDenied(
                    error == "access_denied" ? "Sign-in was cancelled." : "Sign-in failed: \(error)"
                )
            }
            guard let code = parameters["code"], !code.isEmpty else {
                throw MusicServiceConnectionError.invalidOAuthCallback
            }

            let token = try await exchangeAuthorizationCode(
                service: service,
                clientID: clientID,
                clientSecret: clientSecret,
                code: code,
                verifier: verifier,
                redirectURL: redirectURL
            )
            guard generations[service] == generation else { throw CancellationError() }
            try saveToken(token, service)
            tokens[service] = token
            states[service] = .connected(accountName: nil)
            await loadPlaylists(for: service)
        } catch {
            guard generations[service] == generation else { return }
            states[service] = .failed(error.localizedDescription)
        }
    }

    func connectUsingSavedCredentials(_ service: MusicPlaylistService) async {
        let defaultsKey = service == .youtube ? Self.youtubeClientIDDefaultsKey : Self.spotifyClientIDDefaultsKey
        let clientID = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        await connect(service, clientID: clientID, clientSecret: Self.savedClientSecret(for: service))
    }

    func disconnect(_ service: MusicPlaylistService) async {
        let token = tokens[service]
        invalidate(service)
        tokens[service] = nil
        deleteToken(service)
        playlists[service] = []
        states[service] = .disconnected
        if let token { await revokeTokenIfSupported(token, for: service) }
    }

    func loadPlaylists(for service: MusicPlaylistService) async {
        guard state(for: service).isConnected, !loadingServices.contains(service) else { return }
        let generation = generation(for: service)
        loadingServices.insert(service)
        playlistErrors[service] = nil
        defer { if generations[service] == generation { loadingServices.remove(service) } }
        do {
            let result: ([RemoteMusicPlaylist], String?)
            switch service {
            case .youtube: result = try await loadYouTubePlaylists()
            case .spotify: result = try await loadSpotifyPlaylists()
            }
            guard generations[service] == generation, !Task.isCancelled else { return }
            playlists[service] = result.0
            states[service] = .connected(accountName: result.1)
        } catch {
            guard generations[service] == generation, !(error is CancellationError), !Task.isCancelled else { return }
            // Keep the account and last successful results available during network failures.
            playlistErrors[service] = error.localizedDescription
        }
    }

    func tracks(for playlist: RemoteMusicPlaylist) async throws -> [RemoteMusicTrack] {
        switch playlist.service {
        case .youtube:
            return try await loadYouTubeTracks(playlistID: playlist.id)
        case .spotify:
            return try await loadSpotifyTracks(playlistID: playlist.id)
        }
    }

    private func makeAuthorizationURL(
        service: MusicPlaylistService,
        clientID: String,
        redirectURL: URL,
        challenge: String,
        state: String
    ) throws -> URL {
        var components: URLComponents
        switch service {
        case .youtube:
            components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/youtube.readonly"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
        case .spotify:
            components = URLComponents(string: "https://accounts.spotify.com/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "playlist-read-private playlist-read-collaborative user-read-private"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
        }
        guard let url = components.url else { throw MusicServiceConnectionError.invalidResponse }
        return url
    }

    private func exchangeAuthorizationCode(
        service: MusicPlaylistService,
        clientID: String,
        clientSecret: String,
        code: String,
        verifier: String,
        redirectURL: URL
    ) async throws -> OAuthToken {
        let endpoint: URL
        switch service {
        case .youtube: endpoint = URL(string: "https://oauth2.googleapis.com/token")!
        case .spotify: endpoint = URL(string: "https://accounts.spotify.com/api/token")!
        }
        var form = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURL.absoluteString,
            "code_verifier": verifier
        ]
        if service == .youtube {
            form["client_secret"] = clientSecret
        }
        return try await requestToken(
            endpoint: endpoint,
            service: service,
            form: form,
            existingRefreshToken: nil
        )
    }

    private func refreshToken(for service: MusicPlaylistService, existingToken: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = existingToken.refreshToken, !refreshToken.isEmpty else {
            throw MusicServiceConnectionError.missingRefreshToken
        }
        let defaultsKey = service == .youtube ? Self.youtubeClientIDDefaultsKey : Self.spotifyClientIDDefaultsKey
        guard let clientID = UserDefaults.standard.string(forKey: defaultsKey), !clientID.isEmpty else {
            throw MusicServiceConnectionError.missingClientID(service)
        }
        let endpoint = service == .youtube
            ? URL(string: "https://oauth2.googleapis.com/token")!
            : URL(string: "https://accounts.spotify.com/api/token")!
        var form = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if service == .youtube {
            guard let clientSecret = OAuthClientSecretStore.load(for: service), !clientSecret.isEmpty else {
                throw MusicServiceConnectionError.missingClientSecret(service)
            }
            form["client_secret"] = clientSecret
        }
        return try await requestToken(
            endpoint: endpoint,
            service: service,
            form: form,
            existingRefreshToken: refreshToken
        )
    }

    private func requestToken(
        endpoint: URL,
        service: MusicPlaylistService,
        form: [String: String],
        existingRefreshToken: String?
    ) async throws -> OAuthToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(form)
        let (data, response) = try await serviceData(for: request, service: service)
        guard let http = response as? HTTPURLResponse else { throw MusicServiceConnectionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MusicServiceConnectionError.apiError(http.statusCode, Self.apiErrorMessage(from: data))
        }
        let responseToken = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return OAuthToken(
            accessToken: responseToken.accessToken,
            refreshToken: responseToken.refreshToken ?? existingRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(responseToken.expiresIn)),
            scope: responseToken.scope
        )
    }

    private func revokeTokenIfSupported(_ token: OAuthToken, for service: MusicPlaylistService) async {
        // Spotify does not expose a public OAuth token-revocation endpoint. Removing
        // its local Keychain token still signs Nightwing out on this Mac.
        guard service == .youtube else { return }
        let credential = token.refreshToken ?? token.accessToken
        guard !credential.isEmpty else { return }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(["token": credential])
        _ = try? await session.data(for: request)
    }

    private func authorizedData(for request: URLRequest, service: MusicPlaylistService, retrying: Bool = false) async throws -> Data {
        guard var token = tokens[service] else { throw MusicServiceConnectionError.notConnected(service) }
        let generation = generation(for: service)
        if token.expiresAt <= Date().addingTimeInterval(60) {
            if let refresh = tokenRefreshes[service] {
                token = try await refresh.value
            } else {
                let existing = token
                let refresh = Task { @MainActor in
                    let refreshed = try await self.refreshToken(for: service, existingToken: existing)
                    guard self.generations[service] == generation else { throw CancellationError() }
                    try self.saveToken(refreshed, service)
                    self.tokens[service] = refreshed
                    return refreshed
                }
                tokenRefreshes[service] = refresh
                defer { if generations[service] == generation { tokenRefreshes[service] = nil } }
                token = try await refresh.value
            }
            guard generations[service] == generation else { throw CancellationError() }
        }

        var authorizedRequest = request
        authorizedRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await serviceData(for: authorizedRequest, service: service)
        guard let http = response as? HTTPURLResponse else { throw MusicServiceConnectionError.invalidResponse }
        if http.statusCode == 401, !retrying {
            token.expiresAt = .distantPast
            tokens[service] = token
            return try await authorizedData(for: request, service: service, retrying: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            var message = Self.apiErrorMessage(from: data)
            if service == .spotify, http.statusCode == 403 {
                message = message.isEmpty
                    ? "Spotify only allows this app to read playlist items that you own or collaborate on."
                    : message
            }
            throw MusicServiceConnectionError.apiError(http.statusCode, message)
        }
        return data
    }

    private func loadYouTubePlaylists() async throws -> ([RemoteMusicPlaylist], String?) {
        async let channelName: String? = loadYouTubeChannelName()
        var output: [RemoteMusicPlaylist] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
            components.queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await authorizedData(for: URLRequest(url: components.url!), service: .youtube)
            let page = try JSONDecoder().decode(YouTubePlaylistPage.self, from: data)
            output.append(contentsOf: page.items.map { item in
                RemoteMusicPlaylist(
                    id: item.id,
                    service: .youtube,
                    name: item.snippet.title,
                    ownerName: item.snippet.channelTitle,
                    itemCount: item.contentDetails.itemCount,
                    artworkURL: item.snippet.bestThumbnailURL,
                    sourceURL: URL(string: "https://music.youtube.com/playlist?list=\(item.id)")
                )
            })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return (output, try await channelName)
    }

    private func loadYouTubeChannelName() async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "mine", value: "true")
        ]
        let data = try await authorizedData(for: URLRequest(url: components.url!), service: .youtube)
        return try JSONDecoder().decode(YouTubeChannelPage.self, from: data).items.first?.snippet.title
    }

    private func loadYouTubeTracks(playlistID: String) async throws -> [RemoteMusicTrack] {
        var output: [RemoteMusicTrack] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            components.queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await authorizedData(for: URLRequest(url: components.url!), service: .youtube)
            let page = try JSONDecoder().decode(YouTubePlaylistItemsPage.self, from: data)
            output.append(contentsOf: page.items.compactMap { item in
                let videoID = item.contentDetails.videoId
                guard !videoID.isEmpty, item.snippet.title != "Deleted video", item.snippet.title != "Private video" else { return nil }
                let parsed = Self.parseYouTubeTitle(item.snippet.title, fallbackArtist: item.snippet.videoOwnerChannelTitle)
                return RemoteMusicTrack(
                    id: videoID,
                    title: parsed.title,
                    artist: parsed.artist,
                    sourceURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                    artworkURL: item.snippet.bestThumbnailURL
                )
            })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return output
    }

    private func loadSpotifyPlaylists() async throws -> ([RemoteMusicPlaylist], String?) {
        async let accountName: String? = loadSpotifyAccountName()
        var output: [RemoteMusicPlaylist] = []
        var offset = 0
        var total = Int.max
        while offset < total {
            var components = URLComponents(string: "https://api.spotify.com/v1/me/playlists")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            let data = try await authorizedData(for: URLRequest(url: components.url!), service: .spotify)
            let page = try JSONDecoder().decode(SpotifyPlaylistPage.self, from: data)
            output.append(contentsOf: page.items.map { item in
                RemoteMusicPlaylist(
                    id: item.id,
                    service: .spotify,
                    name: item.name,
                    ownerName: item.owner?.displayName,
                    itemCount: item.items?.total ?? item.tracks?.total ?? 0,
                    artworkURL: item.images?.first?.url,
                    sourceURL: item.externalURLs?.spotify
                )
            })
            total = page.total
            offset += page.items.count
            if page.items.isEmpty { break }
        }
        return (output, try await accountName)
    }

    private func loadSpotifyAccountName() async throws -> String? {
        let data = try await authorizedData(for: URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!), service: .spotify)
        return try JSONDecoder().decode(SpotifyProfile.self, from: data).displayName
    }

    private func loadSpotifyTracks(playlistID: String) async throws -> [RemoteMusicTrack] {
        var output: [RemoteMusicTrack] = []
        var offset = 0
        var total = Int.max
        while offset < total {
            var components = URLComponents(string: "https://api.spotify.com/v1/playlists/\(playlistID)/items")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            let data = try await authorizedData(for: URLRequest(url: components.url!), service: .spotify)
            let page = try JSONDecoder().decode(SpotifyPlaylistItemsPage.self, from: data)
            output.append(contentsOf: page.items.compactMap { wrapper in
                guard let item = wrapper.item, item.type == nil || item.type == "track" else { return nil }
                return RemoteMusicTrack(
                    id: item.id ?? item.uri ?? UUID().uuidString,
                    title: item.name,
                    artist: item.artists?.map(\.name).joined(separator: ", "),
                    album: item.album?.name,
                    duration: item.durationMilliseconds.map { TimeInterval($0) / 1_000 },
                    sourceURL: item.externalURLs?.spotify,
                    artworkURL: item.album?.images?.first?.url
                )
            })
            total = page.total
            offset += page.items.count
            if page.items.isEmpty { break }
        }
        return output
    }

    private static func parseYouTubeTitle(_ rawTitle: String, fallbackArtist: String?) -> (title: String, artist: String?) {
        let separators = [" - ", " – ", " — "]
        for separator in separators {
            let parts = rawTitle.components(separatedBy: separator)
            if parts.count >= 2 {
                return (parts.dropFirst().joined(separator: separator), parts.first)
            }
        }
        return (rawTitle, fallbackArtist)
    }

    nonisolated static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MusicServiceConnectionError.secureRandomFailure
        }
        return Data(bytes).base64URLEncodedString()
    }

    nonisolated static func oauthParameters(from callbackURL: URL) -> [String: String] {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.reduce(into: [:]) { parameters, item in
            // Keep the first occurrence so a duplicate query item cannot replace
            // an already-validated value or crash Dictionary construction.
            if parameters[item.name] == nil {
                parameters[item.name] = item.value ?? ""
            }
        }
    }

    private static func formEncoded(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func apiErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        return ""
    }
}

struct OAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?
}

private struct OAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private enum OAuthClientSecretStore {
    private static let keychainService = "com.rayzhu.nightwing.oauth-client-secrets"

    static func load(for service: MusicPlaylistService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String, for service: MusicPlaylistService) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insertion[kSecAttrSynchronizable as String] = false
            let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else {
                throw MusicServiceConnectionError.apiError(Int(insertionStatus), "Nightwing could not save the OAuth client secret securely.")
            }
        } else if status != errSecSuccess {
            throw MusicServiceConnectionError.apiError(Int(status), "Nightwing could not update the OAuth client secret securely.")
        }
    }
}

private enum OAuthTokenStore {
    private static let keychainService = "com.rayzhu.nightwing.music-services"

    static func load(for service: MusicPlaylistService) -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    static func save(_ token: OAuthToken, for service: MusicPlaylistService) throws {
        let data = try JSONEncoder().encode(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insertion[kSecAttrSynchronizable as String] = false
            let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else {
                throw MusicServiceConnectionError.apiError(Int(insertionStatus), "Nightwing could not save the sign-in securely.")
            }
        } else if status != errSecSuccess {
            throw MusicServiceConnectionError.apiError(Int(status), "Nightwing could not update the saved sign-in.")
        }
    }

    static func delete(for service: MusicPlaylistService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private final class LoopbackOAuthReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.rayzhu.nightwing.oauth-loopback")
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var bufferedCallback: Result<URL, Error>?
    private var didResolveStart = false
    private var didFinishCallback = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.didResolveStart else { return }
                    self.didResolveStart = true
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback") else {
                        continuation.resume(throwing: MusicServiceConnectionError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: url)
                case .cancelled:
                    guard !self.didResolveStart else { return }
                    self.didResolveStart = true
                    continuation.resume(throwing: CancellationError())
                case .failed(let error):
                    guard !self.didResolveStart else { return }
                    self.didResolveStart = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(.failure(MusicServiceConnectionError.authorizationDenied("Sign-in timed out. Please try again.")))
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.bufferedCallback {
                    self.bufferedCallback = nil
                    continuation.resume(with: result)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            let result: Result<URL, Error>
            if let data,
               let request = String(data: data, encoding: .utf8),
               let requestLine = request.components(separatedBy: "\r\n").first,
               requestLine.hasPrefix("GET "),
               let target = requestLine.split(separator: " ").dropFirst().first,
               let callbackURL = URL(string: "http://127.0.0.1\(target)") {
                result = .success(callbackURL)
            } else {
                result = .failure(error ?? MusicServiceConnectionError.invalidOAuthCallback)
            }

            let body = "<html><head><meta name='referrer' content='no-referrer'><script>history.replaceState(null,'','/callback')</script></head><body style='font-family:-apple-system;padding:48px'><h2>Authorization received</h2><p>Nightwing is completing sign-in. You can close this window and check the connection status in the app.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.finish(result)
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !didFinishCallback else { return }
        didFinishCallback = true
        listener.cancel()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else {
            bufferedCallback = result
        }
    }
}

private struct YouTubePlaylistPage: Decodable {
    var items: [Item]
    var nextPageToken: String?

    struct Item: Decodable {
        var id: String
        var snippet: YouTubeSnippet
        var contentDetails: ContentDetails
    }

    struct ContentDetails: Decodable { var itemCount: Int }
}

private struct YouTubeChannelPage: Decodable {
    var items: [Item]
    struct Item: Decodable { var snippet: Snippet }
    struct Snippet: Decodable { var title: String }
}

private struct YouTubePlaylistItemsPage: Decodable {
    var items: [Item]
    var nextPageToken: String?

    struct Item: Decodable {
        var snippet: YouTubeSnippet
        var contentDetails: ContentDetails
    }

    struct ContentDetails: Decodable { var videoId: String }
}

private struct YouTubeSnippet: Decodable {
    var title: String
    var channelTitle: String?
    var videoOwnerChannelTitle: String?
    var thumbnails: [String: Thumbnail]?

    struct Thumbnail: Decodable {
        var url: URL
        var width: Int?
        var height: Int?
    }

    var bestThumbnailURL: URL? {
        thumbnails?.values.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
    }
}

private struct SpotifyPlaylistPage: Decodable {
    var items: [Item]
    var total: Int

    struct Item: Decodable {
        var id: String
        var name: String
        var owner: Owner?
        var images: [Image]?
        var items: Count?
        var tracks: Count?
        var externalURLs: ExternalURLs?

        struct Owner: Decodable {
            var displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
        struct Count: Decodable { var total: Int }
        struct Image: Decodable { var url: URL }
        enum CodingKeys: String, CodingKey {
            case id, name, owner, images, items, tracks
            case externalURLs = "external_urls"
        }
    }
}

private struct SpotifyProfile: Decodable {
    var displayName: String?
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

private struct SpotifyPlaylistItemsPage: Decodable {
    var items: [Wrapper]
    var total: Int

    struct Wrapper: Decodable {
        var item: SpotifyTrack?

        enum CodingKeys: String, CodingKey { case item, track }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            item = try container.decodeIfPresent(SpotifyTrack.self, forKey: .item)
                ?? container.decodeIfPresent(SpotifyTrack.self, forKey: .track)
        }
    }
}

private struct SpotifyTrack: Decodable {
    var id: String?
    var uri: String?
    var type: String?
    var name: String
    var artists: [Artist]?
    var album: Album?
    var durationMilliseconds: Int?
    var externalURLs: ExternalURLs?

    struct Artist: Decodable { var name: String }
    struct Album: Decodable {
        var name: String?
        var images: [SpotifyPlaylistPage.Item.Image]?
    }
    enum CodingKeys: String, CodingKey {
        case id, uri, type, name, artists, album
        case durationMilliseconds = "duration_ms"
        case externalURLs = "external_urls"
    }
}

private struct ExternalURLs: Decodable {
    var spotify: URL?
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
