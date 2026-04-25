import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            MemoComposeView()
                .tabItem { Label("Memo", systemImage: "square.and.pencil") }
            NotesListView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            GraphView()
                .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .badge(setupBadge)
        }
        .overlay(alignment: .top) {
            if appState.queueCount > 0 {
                Text("\(appState.queueCount) draft(s) pending — Settings → Retry")
                    .font(.caption)
                    .padding(6)
                    .background(.yellow.opacity(0.85))
                    .cornerRadius(6)
                    .padding(.top, 4)
            }
        }
    }

    private var setupBadge: Int {
        var count = 0
        if !appState.hasAPIKey { count += 1 }
        if !appState.driveAuthorised { count += 1 }
        return count
    }
}
