import SwiftUI

@main
struct NightwingIOSApp: App {
    @StateObject private var appModel = NightwingAppModel()

    var body: some Scene {
        WindowGroup {
            iPhoneRootView()
                .environmentObject(appModel)
                .environmentObject(appModel.player)
        }
    }
}
