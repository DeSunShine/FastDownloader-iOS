import SwiftUI

struct BrowserView: View {
    @ObservedObject var store: BrowserStore
    @State private var showTabs = false

    var body: some View {
        NavigationStack {
            ZStack {
                if store.tabs.isEmpty {
                    ProgressView()
                } else {
                    ForEach(store.tabs) { tab in
                        let isActive = store.selectedTabID == tab.id

                        ActiveBrowserTabView(
                            tab: tab,
                            store: store,
                            onShowTabs: { showTabs = true }
                        )
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .zIndex(isActive ? 1 : 0)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.24), value: store.selectedTabID)
            .navigationTitle("FastDownloader")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            store.ensureInitialTab()
        }
        .sheet(isPresented: $showTabs) {
            TabSwitcherView(store: store, isPresented: $showTabs)
        }
    }
}

private struct ActiveBrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    let onShowTabs: () -> Void

    @State private var address = ""
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

                if !address.isEmpty {
                    Button {
                        address = ""
                        addressFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                }

                if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    onShowTabs()
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
                    createAndSwitchToNewTab()
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
    }

    private func navigateFromAddress() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        if let targetURL = store.navigate(value, in: tab) {
            address = targetURL.absoluteString
        }

        DispatchQueue.main.async {
            addressFocused = false
        }
    }

    private func createAndSwitchToNewTab() {
        let newTab = store.addTab(
            url: URL(string: "https://www.google.com"),
            select: false
        )

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.24)) {
                store.select(newTab.id)
            }
        }
    }
}

private struct TabSwitcherView: View {
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool
    @Environment(\.editMode) private var editMode

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.tabs) { tab in
                    tabRow(tab)
                }
                .onMove { source, destination in
                    withAnimation(.snappy(duration: 0.22)) {
                        store.moveTabs(fromOffsets: source, toOffset: destination)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
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
                        addTabWithoutClosingSwitcher()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Tab")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder
    private func tabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
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
                withAnimation(.easeInOut(duration: 0.24)) {
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
    }

    private func addTabWithoutClosingSwitcher() {
        let newTab = store.addTab(
            url: URL(string: "https://www.google.com"),
            select: false
        )

        withAnimation(.snappy(duration: 0.22)) {
            store.select(newTab.id)
        }
    }
}
