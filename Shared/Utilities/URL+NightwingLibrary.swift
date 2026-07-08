import Foundation

public extension URL {
    var nightwingIsSupportedAudioFile: Bool {
        AudioFileType.isSupported(self)
    }
}
