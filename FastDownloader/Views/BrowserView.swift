import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        NavigationStack {
            Group {
                if let tab = store.currentTab {
                    ActiveBrowserTabView(tab: tab, store: store)
                        .id(tab.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.995)))
                } else {
                    ProgressView()
                }
            }
            .animation(.easeInOut(duration: 0.18), value: store.selectedTabID)
            .navigationTitle("FastDownloader")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            store.ensureInitialTab()
        }
    }
}

private struct ActiveBrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @State private var address = ""
    @State private var showTabs = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search or enter address", text: $address)
                    .focused($addressFocused)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        navigateFromAddress()
                    }

                if addressFocused && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        navigateFromAddress()
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go")
                } else if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.thinMaterial)

            BrowserContainer(tab: tab)
                .id(tab.id)

            Divider()

            HStack {
                Button {
                    tab.webView.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!tab.canGoBack)

                Spacer()

                Button {
                    tab.webView.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!tab.canGoForward)

                Spacer()

                Button {
                    if tab.isLoading {
                        tab.webView.stopLoading()
                    } else {
                        tab.webView.reload()
                    }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }

                Spacer()

                Button {
                    showTabs = true
                } label: {
                    ZStack {
                        Image(systemName: "square.on.square")
                        Text("\(store.tabs.count)")
                            .font(.system(size: 9, weight: .bold))
                            .offset(y: -1)
                    }
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        _ = store.addTab(url: URL(string: "https://www.google.com"), select: true)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Tab")
            }
            .font(.title3)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear {
            address = tab.urlString ?? ""
        }
        .onChange(of: tab.urlString) { _, newValue in
            guard !addressFocused else { return }
            address = newValue ?? ""
        }
        .sheet(isPresented: $showTabs) {
            TabSwitcherView(store: store, isPresented: $showTabs)
        }
    }

    private func navigateFromAddress() {
        let value = address
        addressFocused = false
        store.navigate(value, in: tab)
    }
}

private struct TabSwitcherView: View {
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool
    @State private var draggedTabID: UUID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.tabs) { tab in
                    tabRow(tab)
                        .contentShape(Rectangle())
                        .draggable(tab.id.uuidString) {
                            tabDragPreview(tab)
                                .onAppear { draggedTabID = tab.id }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard
                                let rawID = items.first,
                                let draggedID = UUID(uuidString: rawID)
                            else { return false }

                            withAnimation(.snappy(duration: 0.22)) {
                                store.moveTab(draggedID, before: tab.id)
                            }
                            draggedTabID = nil
                            return true
                        } isTargeted: { targeted in
                            if !targeted && draggedTabID == tab.id {
                                draggedTabID = nil
                            }
                        }
                }
            }
            .animation(.snappy(duration: 0.22), value: store.tabs.map(\.id))
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            _ = store.addTab(url: URL(string: "https://www.google.com"), select: true)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Tab")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func tabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if store.selectedTabID == tab.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Text(tab.title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }

                Text(tab.urlString ?? "New Tab")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.select(tab.id)
                }
                isPresented = false
            }

            Button(role: .destructive) {
                withAnimation(.snappy(duration: 0.22)) {
                    store.close(tab.id)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Tab")
        }
        .padding(.vertical, 2)
        .opacity(draggedTabID == tab.id ? 0.55 : 1)
    }

    private func tabDragPreview(_ tab: BrowserTab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .lineLimit(1)
                    .font(.headline)
                Text(tab.urlString ?? "New Tab")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
