import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Downloads captured by the browser will appear here.")
                    )
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.headline)
                        .lineLimit(2)

                    Text(item.state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                actionButtons
            }

            if item.state == .downloading || item.state == .paused {
                ProgressView(value: item.progress)
                HStack {
                    Text(ByteFormatter.string(item.receivedBytes))
                    if item.expectedBytes > 0 {
                        Text("of " + ByteFormatter.string(item.expectedBytes))
                    }
                    Spacer()
                    if item.expectedBytes > 0 {
                        Text("\(Int(item.progress * 100))%")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let error = item.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let hash = item.sha256 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SHA-256")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(hash)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                manager.delete(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            switch item.state {
            case .downloading:
                Button {
                    manager.pause(id: item.id)
                } label: {
                    Image(systemName: "pause.circle.fill")
                }
                .buttonStyle(.borderless)

            case .paused:
                Button {
                    manager.resume(id: item.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .buttonStyle(.borderless)

            case .failed:
                Button {
                    manager.retry(id: item.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
                .buttonStyle(.borderless)

            case .completed:
                if let url = manager.localURL(for: item) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }

            case .queued, .verifying:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.title3)
    }

    private var iconName: String {
        switch item.state {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle"
        case .verifying: return "checkmark.shield"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .accentColor
        }
    }
}
