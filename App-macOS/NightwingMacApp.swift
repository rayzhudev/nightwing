import SwiftUI

@main
struct NightwingMacApp: App {
    @StateObject private var appModel = NightwingAppModel()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environmentObject(appModel)
                .environmentObject(appModel.player)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            SidebarCommands()
            PlaybackCommands(appModel: appModel)
        }
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
