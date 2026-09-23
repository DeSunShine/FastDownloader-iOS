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
                        description: Text("Open a downloadable file in Browser or long-press a link and choose Download Link.")
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.title3)
                    .frame(width: 24, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(item.state.title)

                        if let host = sourceHost {
                            Text("•")
                            Text(host)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                actionButtons
            }

            progressSection

            if let error = item.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.vertical, 5)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                manager.delete(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        switch item.state {
        case .downloading:
            if item.expectedBytes > 0 {
                ProgressView(value: item.progress)
            } else {
                ProgressView()
            }

            HStack(spacing: 6) {
                Text(ByteFormatter.string(item.receivedBytes))

                if item.expectedBytes > 0 {
                    Text("of")
                    Text(ByteFormatter.string(item.expectedBytes))
                }

                Spacer()

                if item.expectedBytes > 0 {
                    Text("\(Int(item.progress * 100))%")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                if let speed = item.bytesPerSecond, speed > 0 {
                    Text(SpeedFormatter.string(speed))
                } else {
                    Text("Measuring speed…")
                }

                if let eta = item.etaSeconds, eta >= 0 {
                    Text("•")
                    Text(DurationFormatter.remaining(eta))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .paused:
            if item.expectedBytes > 0 {
                ProgressView(value: item.progress)
            }

            HStack {
                Text(ByteFormatter.string(item.receivedBytes))
                if item.expectedBytes > 0 {
                    Text("of " + ByteFormatter.string(item.expectedBytes))
                }
                Spacer()
                Text("Paused")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Calculating SHA-256…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .completed:
            HStack {
                if item.receivedBytes > 0 {
                    Text(ByteFormatter.string(item.receivedBytes))
                }
                Spacer()
                Text("Saved to Files")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

        case .failed:
            if item.receivedBytes > 0 {
                Text(ByteFormatter.string(item.receivedBytes) + " received before failure")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .queued:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting to start…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 11) {
            switch item.state {
            case .downloading:
                Button {
                    manager.pause(id: item.id)
                } label: {
                    Image(systemName: "pause.circle.fill")
                }
                .accessibilityLabel("Pause")
                .buttonStyle(.borderless)

            case .paused:
                Button {
                    manager.resume(id: item.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .accessibilityLabel("Resume")
                .buttonStyle(.borderless)

            case .failed:
                Button {
                    manager.retry(id: item.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
                .accessibilityLabel("Retry")
                .buttonStyle(.borderless)

            case .completed:
                if let url = manager.localURL(for: item) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    .buttonStyle(.borderless)
                }

            case .queued, .verifying:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.title2)
    }

    private var sourceHost: String? {
        URL(string: item.sourceURL)?.host
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
