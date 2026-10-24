import Foundation
#if os(macOS)
import CoreServices
#endif

/// Recursive filesystem notifications on macOS; periodic reconciliation remains the fallback.
final class WatchedFolderMonitor: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var accessedURLs: [URL] = []
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif

    init(urls: [URL], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        #if os(macOS)
        guard !urls.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WatchedFolderMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context, urls.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        #endif
    }

    deinit {
        #if os(macOS)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        #endif
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
