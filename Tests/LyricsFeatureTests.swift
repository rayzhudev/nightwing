import Foundation
import Testing
@testable import Nightwing_macOS

struct LyricsFeatureTests {
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
