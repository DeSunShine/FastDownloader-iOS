import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct FastDownloaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var browser = BrowserStore()

    var body: some Scene {
        WindowGroup {
            RootView(browser: browser)
                .environmentObject(downloads)
                .environmentObject(settings)
        }
    }
}
