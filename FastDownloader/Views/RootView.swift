import SwiftUI

struct RootView: View {
    @ObservedObject var browser: BrowserStore
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.selectedTab) {
            BrowserView(store: browser)
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }
                .tag(AppRouter.Tab.browser.rawValue)

            DownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .badge(activeDownloadCount)
                .tag(AppRouter.Tab.downloads.rawValue)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppRouter.Tab.settings.rawValue)
        }
    }

    private var activeDownloadCount: Int {
        downloads.items.filter {
            $0.state == .queued || $0.state == .downloading || $0.state == .paused || $0.state == .merging || $0.state == .verifying
        }.count
    }
}
