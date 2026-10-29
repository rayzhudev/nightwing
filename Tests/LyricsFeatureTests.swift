import Foundation
import Testing
@testable import Nightwing_macOS

struct LyricsFeatureTests {
    @Test func defaultModelSizeMatchesDownloadManifest() {
        let manifest = LyricsModelDownloadService.Manifest()
        #expect(manifest.expectedDownloadBytes == LyricsModelDownloadService.defaultModelDownloadBytes)
    }

    @Test func parsesSyncedLyrics() {
        let value = "[00:01.25] First line\n[00:04.50] Second line"
        let lines = CanonicalLyricsService.parseLRC(value, trackDuration: 8)

        #expect(lines.count == 2)
        #expect(abs(lines[0].startTime - 1.25) < 0.001)
        #expect(abs(lines[0].endTime - 4.5) < 0.001)
        #expect(lines[1].text == "Second line")
    }

    @Test func alignsCanonicalTextToTranscriptTiming() {
        let transcript = [
            LyricsLine(startTime: 1, endTime: 3, text: "first ASR line"),
            LyricsLine(startTime: 4, endTime: 6, text: "second ASR line")
        ]

        let lines = CanonicalLyricsService.align(["First line", "Second line"], to: transcript)

        #expect(lines.map(\.text) == ["First line", "Second line"])
        #expect(lines.map(\.startTime) == [1, 4])
    }

    @Test func sidecarRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightwingLyricsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricsSidecarStore(directoryURL: directory)
        let document = LyricsDocument(
            trackID: UUID(),
            trackTitle: "Test",
            sourceFilePath: "/tmp/test.flac",
            modelName: "test",
            transcriptionSpeed: 1,
            lines: [LyricsLine(startTime: 0, endTime: 1, text: "Hello")]
        )

        try await store.save(document, cacheKey: "round-trip")
        let loaded = try await store.load(cacheKey: "round-trip")

        #expect(loaded?.trackID == document.trackID)
        #expect(loaded?.trackTitle == document.trackTitle)
        #expect(loaded?.modelName == document.modelName)
        #expect(loaded?.lines == document.lines)
    }

    #if os(macOS)
    @Test func modelAvailabilityCheckDoesNotStartADownload() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightwingModelAvailabilityTests-\(UUID().uuidString)", isDirectory: true)
        let modelURL = rootURL.appendingPathComponent("model", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = LyricsModelDownloadService(
            manifest: .init(
                name: "test/model",
                sourceBaseURL: URL(string: "https://example.com/model")!,
                files: ["config.json", "model.bin"],
                sha256: [:]
            ),
            directoryURL: modelURL,
            huggingFaceCacheURL: cacheURL
        )

        #expect(await service.availableModelURL() == nil)

        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: modelURL.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: modelURL.appendingPathComponent("model.bin"))

        #expect(await service.availableModelURL() == modelURL)
    }

    @Test func modelIntegrityRejectsCorruptionWithoutDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LyricsModelDownloadService(manifest: .init(name: "test", files: ["config.json"], sha256: ["config.json": "0000000000000000000000000000000000000000000000000000000000000000"]), directoryURL: root, huggingFaceCacheURL: root.appendingPathComponent("no-cache"))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("config.json"))
        #expect(await service.availableModelURL() == nil)
    }

    @Test func runtimeProvisioningIsSingleFlightAndCancellationIsPerWaiter() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightwingRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        let runtimeURL = rootURL.appendingPathComponent("runtime", isDirectory: true)
        let pythonURL = rootURL.appendingPathComponent("fake-python")
        let probesURL = rootURL.appendingPathComponent("probes.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let script = """
        #!/bin/sh
        script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
        printf 'probe\\n' >> "$script_dir/probes.txt"
        /bin/sleep 0.4
        exit 0
        """
        try script.write(to: pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: pythonURL.path
        )

        let service = LyricsRuntimeService(
            directoryURL: runtimeURL,
            preferredPythonPath: pythonURL.path
        )
        let firstWaiter = Task { try await service.pythonPath() }
        try await Task.sleep(for: .milliseconds(50))
        let secondWaiter = Task { try await service.pythonPath() }
        try await Task.sleep(for: .milliseconds(50))
        firstWaiter.cancel()

        var firstWaiterWasCancelled = false
        do {
            _ = try await firstWaiter.value
        } catch is CancellationError {
            firstWaiterWasCancelled = true
        }
        let resolvedPath = try await secondWaiter.value
        let probes = try String(contentsOf: probesURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)

        #expect(firstWaiterWasCancelled)
        #expect(resolvedPath == pythonURL.path)
        #expect(probes.count == 1)
        #expect(FileManager.default.fileExists(atPath: runtimeURL.path))
        #expect(FileManager.default.fileExists(atPath: runtimeURL.appendingPathComponent("runtime-install.log").path))
    }
    #endif
}

@Suite(.serialized)
struct ReliabilityTests {
    @Test func testHostUsesSeparateLibraryPreferencesAndAccounts() async throws {
        #expect(NightwingEnvironment.isIsolated)
        #expect(NightwingEnvironment.isTestHost)
        let store = try JSONLocalLibraryStore.defaultStore()
        let fileURL = await store.fileURL
        #expect(fileURL.path.hasPrefix(NightwingEnvironment.profileDirectory!.path))
        #expect(!fileURL.path.hasPrefix(NSHomeDirectory() + "/Library/Application Support"))
        #expect(NightwingEnvironment.defaults !== UserDefaults.standard)
        let connections = await MusicServiceConnections()
        #expect(await connections.state(for: .youtube) == .disconnected)
        #expect(await connections.state(for: .spotify) == .disconnected)
    }

    @Test func lyricsOfflineRequestPropagatesAnErrorWithoutDataLoss() async throws {
        TestMusicURLProtocol.mode = .failure
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = CanonicalLyricsService(session: session)
        let track = Track(fileURL: URL(fileURLWithPath: "/tmp/test.wav"), title: "Test", artist: "Test", album: "Test", duration: 2, fileType: .wav)
        await #expect(throws: URLError.self) { try await service.lyrics(for: track) }
    }

    @Test @MainActor func oauthUserDenialDoesNotPersistToken() async throws {
        var callbackTask: Task<Void, Never>?
        let connections = MusicServiceConnections(openAuthorizationURL: { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            let state = query.first { $0.name == "state" }!.value!
            var callback = URLComponents(string: redirect)!
            callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "error", value: "access_denied")]
            let callbackURL = callback.url!
            callbackTask = Task { _ = try? await URLSession.shared.data(from: callbackURL) }
            return true
        }, loadToken: { _ in nil }, saveToken: { _, _ in Issue.record("Denied authorisation persisted a token") }, deleteToken: { _ in })
        await connections.connect(.spotify, clientID: "test-client")
        await callbackTask?.value
        #expect(connections.state(for: .spotify) == .failed("Sign-in was cancelled."))
    }

    @Test @MainActor func cancellingOAuthTaskStopsCallbackWait() async throws {
        var didOpen = false
        let connections = MusicServiceConnections(openAuthorizationURL: { _ in didOpen = true; return true }, loadToken: { _ in nil }, saveToken: { _, _ in Issue.record("Cancelled OAuth saved a token") }, deleteToken: { _ in })
        let task = Task { await connections.connect(.spotify, clientID: "test-client") }
        for _ in 0..<200 where !didOpen { try await Task.sleep(for: .milliseconds(5)) }
        #expect(didOpen)
        task.cancel()
        await task.value
        #expect(!connections.state(for: .spotify).isConnected)
    }

    @Test @MainActor func googleDisconnectAttemptsRemoteRevocationAndAlwaysDeletesLocalToken() async throws {
        TestMusicURLProtocol.mode = .success
        TestMusicURLProtocol.didRevoke = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var deleted = false
        let connections = MusicServiceConnections(session: session, loadToken: { service in
            service == .youtube ? OAuthToken(accessToken: "test", expiresAt: .distantFuture) : nil
        }, saveToken: { _, _ in }, deleteToken: { service in deleted = service == .youtube })
        await connections.disconnect(.youtube)
        #expect(deleted)
        #expect(TestMusicURLProtocol.didRevoke)
        #expect(connections.state(for: .youtube) == .disconnected)
    }

    @Test func libraryRecoveryPreservesOriginalAndRestoresBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = JSONLocalLibraryStore(fileURL: url)
        var library = LocalLibrary.empty
        library.upsertTracks([Track(fileURL: URL(fileURLWithPath: "/tmp/song.mp3"), title: "Saved song", fileType: .mp3)])
        try await store.save(library)
        let broken = Data("invalid library".utf8)
        try broken.write(to: url)
        let loaded = try await store.load()
        #expect(loaded.tracks.map(\.title) == ["Saved song"])
        #expect(await store.recoveryNotice != nil)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("unreadable-") }
        #expect(try Data(contentsOf: #require(preserved)) == broken)
        try await store.save(loaded)
        #expect(try await store.load().tracks.count == 1)
    }

    @Test func unreadableLibraryCannotBeOverwrittenWithoutRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let broken = Data("unreadable".utf8)
        try broken.write(to: url)
        let store = JSONLocalLibraryStore(fileURL: url)
        await #expect(throws: JSONLocalLibraryStore.StoreError.self) { try await store.load() }
        await #expect(throws: JSONLocalLibraryStore.StoreError.self) { try await store.save(.empty) }
        #expect(try Data(contentsOf: url) == broken)
        // A fresh store also validates before writing, even without a preceding load.
        let fresh = JSONLocalLibraryStore(fileURL: url)
        await #expect(throws: JSONLocalLibraryStore.StoreError.self) { try await fresh.save(.empty) }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func syncedLyricsExpandRepeatsSortAndApplyOffset() {
        let lyrics = "[00:30][00:10.50]Chorus\n[00:02]Verse\n[offset:500]"
        let lines = CanonicalLyricsService.parseLRC(lyrics, trackDuration: 40)
        #expect(lines.map(\.text) == ["Verse", "Chorus", "Chorus"])
        #expect(lines.map(\.startTime) == [1.5, 10, 29.5])
        #expect(lines.map(\.endTime) == [10, 29.5, 40])
    }

    @Test func negativeOffsetAndLiteralBracketsArePreserved() {
        let lines = CanonicalLyricsService.parseLRC("[offset:-1000]\n[00:00]Sing [00:10] aloud\n[00:99]Invalid", trackDuration: 5)
        #expect(lines.count == 1)
        #expect(lines.first?.startTime == 1)
        #expect(lines.first?.text == "Sing [00:10] aloud")
    }

    @Test @MainActor func lyricsQueueSerializesPromotesAndCancels() async throws {
        let queue = LyricsGenerationQueue()
        let active = UUID(), background = UUID(), requested = UUID(), cancelled = UUID()
        try await queue.acquire(active, priority: false)
        let backTask = Task { try await queue.acquire(background, priority: false) }
        let requestTask = Task { try await queue.acquire(requested, priority: false) }
        let cancelledTask = Task { try await queue.acquire(cancelled, priority: true) }
        for _ in 0..<100 where queue.pendingIDs.count < 3 { await Task.yield() }
        #expect(queue.activeID == active)
        #expect(queue.pendingIDs.count == 3)
        queue.promote(requested)
        cancelledTask.cancel()
        do { try await cancelledTask.value; Issue.record("Cancelled job acquired the worker") } catch is CancellationError {}
        #expect(queue.pendingIDs == [requested, background])
        queue.release(active)
        try await requestTask.value
        #expect(queue.activeID == requested)
        #expect(queue.pendingIDs == [background])
        queue.release(requested)
        try await backTask.value
        #expect(queue.activeID == background)
        queue.release(background)
        #expect(queue.activeID == nil)
    }

    @Test func existingLyricsBypassModelAndRuntime() async throws {
        let source = URL(fileURLWithPath: "/tmp/not-needed.mp3")
        let track = Track(fileURL: source, title: "Song", fileType: .mp3)
        let service = LyricsTranscriptionService(modelDownloadService: nil, canonicalLookup: { _ in
            .synced([LyricsLine(startTime: 0, endTime: 2, text: "Existing lyrics")])
        })
        let result = try await service.transcribe(track: track, sourceURL: source)
        #expect(result.lines.first?.text == "Existing lyrics")
        #expect(result.modelName == "LRCLIB synced lyrics")
    }

    @Test func disablingOnlineLookupDoesNotCallTheService() async throws {
        let source = URL(fileURLWithPath: "/tmp/not-needed.mp3")
        let track = Track(fileURL: source, title: "Song", fileType: .mp3)
        let service = LyricsTranscriptionService(modelDownloadService: nil, canonicalLookup: { _ in
            Issue.record("Online lookup was called despite the disabled setting")
            return nil
        })
        await #expect(throws: LyricsTranscriptionService.TranscriptionError.self) {
            try await service.transcribe(track: track, sourceURL: source, lookupOnline: false)
        }
    }

    @Test @MainActor func disconnectCancelsRefreshAndCannotReconnectFromLateResults() async throws {
        TestMusicURLProtocol.mode = .delayed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connections = MusicServiceConnections(session: session, loadToken: { service in
            service == .spotify ? OAuthToken(accessToken: "test", expiresAt: .distantFuture) : nil
        }, saveToken: { _, _ in Issue.record("Unexpected token persistence") }, deleteToken: { _ in })
        let refresh = Task { await connections.loadPlaylists(for: .spotify) }
        for _ in 0..<100 where !connections.loadingServices.contains(.spotify) { await Task.yield() }
        #expect(connections.loadingServices.contains(.spotify))
        await connections.disconnect(.spotify)
        await refresh.value
        #expect(connections.state(for: .spotify) == .disconnected)
        #expect(connections.playlists(for: .spotify).isEmpty)
        #expect(connections.playlistErrors[.spotify] == nil)
        #expect(!connections.loadingServices.contains(.spotify))
    }

    @Test @MainActor func playlistFailureKeepsConnectionAndRetryClearsError() async throws {
        TestMusicURLProtocol.mode = .failure
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connections = MusicServiceConnections(session: session, loadToken: { service in
            service == .spotify ? OAuthToken(accessToken: "test", expiresAt: .distantFuture) : nil
        }, saveToken: { _, _ in }, deleteToken: { _ in })
        await connections.loadPlaylists(for: .spotify)
        #expect(connections.state(for: .spotify).isConnected)
        #expect(connections.playlistErrors[.spotify] != nil)
        TestMusicURLProtocol.mode = .success
        await connections.loadPlaylists(for: .spotify)
        #expect(connections.state(for: .spotify).isConnected)
        #expect(connections.playlistErrors[.spotify] == nil)
    }
}

private final class TestMusicURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case delayed, failure, success }
    private static let lock = NSLock()
    private static var storedRevoke = false
    static var didRevoke: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedRevoke }
        set { lock.lock(); defer { lock.unlock() }; storedRevoke = newValue }
    }
    private static var storedMode = Mode.success
    static var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return storedMode }
        set { lock.lock(); defer { lock.unlock() }; storedMode = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/revoke" { Self.didRevoke = true }
        switch Self.mode {
        case .delayed: break // The session must cancel this outstanding request on disconnect.
        case .failure: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .success:
            let body = request.url?.path == "/v1/me" ? "{\"display_name\":\"Test\"}" : "{\"items\":[],\"total\":0}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
