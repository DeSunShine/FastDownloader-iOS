import SwiftUI

struct RootView: View {
    @ObservedObject var browser: BrowserStore
    @EnvironmentObject private var downloads: DownloadManager

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
                .badge(activeDownloadCount)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }

    private var activeDownloadCount: Int {
        downloads.items.filter {
            $0.state == .queued || $0.state == .downloading || $0.state == .paused || $0.state == .verifying
        }.count
    }
}
