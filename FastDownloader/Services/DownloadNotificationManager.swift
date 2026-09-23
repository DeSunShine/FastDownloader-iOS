import Foundation
import Combine
import UserNotifications

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Int {
        case browser = 0
        case downloads = 1
        case settings = 2
    }

    @Published var selectedTab: Int = Tab.browser.rawValue

    private init() {}
}

final class DownloadNotificationManager {
    static let shared = DownloadNotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let permissionRequestedKey = "notifications.downloadPermissionRequested"

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard AppSettings.shared.downloadNotifications else { return }
        guard !UserDefaults.standard.bool(forKey: permissionRequestedKey) else { return }

        UserDefaults.standard.set(true, forKey: permissionRequestedKey)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyCompleted(_ item: DownloadItem) {
        guard AppSettings.shared.downloadNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"

        var parts = [item.filename]
        if item.receivedBytes > 0 {
            parts.append(ByteFormatter.string(item.receivedBytes))
        }
        if let integrity = item.integrityStatus {
            parts.append(integrity.title)
        }

        content.body = parts.joined(separator: " • ")
        content.sound = .default
        content.userInfo = [
            "destination": "downloads",
            "downloadID": item.id.uuidString
        ]

        deliver(content, identifier: "download-complete-" + item.id.uuidString)
    }

    func notifyFailed(_ item: DownloadItem) {
        guard AppSettings.shared.downloadNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Download Failed"

        if let error = item.errorMessage, !error.isEmpty {
            content.body = item.filename + " • " + error
        } else {
            content.body = item.filename
        }

        content.sound = .default
        content.userInfo = [
            "destination": "downloads",
            "downloadID": item.id.uuidString
        ]

        deliver(content, identifier: "download-failed-" + item.id.uuidString)
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: nil
                )
                self.center.add(request)
            case .notDetermined:
                self.requestAuthorizationIfNeeded()
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }
}
