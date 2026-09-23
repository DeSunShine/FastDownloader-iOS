import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    Toggle("Allow Cellular Data", isOn: $settings.allowCellular)
                    Toggle("Allow Low Data Mode", isOn: $settings.allowConstrained)
                }

                Section("Downloads") {
                    Toggle("Download Notifications", isOn: $settings.downloadNotifications)
                    Toggle("Calculate SHA-256 After Download", isOn: $settings.verifyDownloads)

                    LabeledContent("Background Engine") {
                        Text("URLSession")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Transfer Mode") {
                        Text("Background single-stream")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Browser") {
                    Toggle("Open Pop-ups in Tabs", isOn: $settings.openPopupsInTabs)
                }

                Section("Files") {
                    Text("Completed files are stored in Files → On My iPhone → FastDownloader → Downloads.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Important iOS Limitation") {
                    Text("Background transfers can continue when the app is suspended, but iOS cancels them if you manually force-quit the app from the app switcher.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
