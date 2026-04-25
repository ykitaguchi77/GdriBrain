import SwiftData
import SwiftUI

@main
struct GdriBrainApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .modelContainer(IndexStack.container)
                .onOpenURL { url in
                    GoogleOAuth.shared.handleRedirect(url: url)
                }
                .task {
                    await appState.bootstrap()
                }
        }
    }
}
