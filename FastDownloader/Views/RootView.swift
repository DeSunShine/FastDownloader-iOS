import SwiftUI

struct RootView: View {
    @ObservedObject var browser: BrowserStore

    var body: some View {
        TabView {
            BrowserView(store: browser)
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }

            DownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
