import SwiftUI

struct BrowserView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        NavigationStack {
            Group {
                if let tab = store.currentTab {
                    ActiveBrowserTabView(tab: tab, store: store)
                        .id(tab.id)
                } else {
                    ProgressView()
                }
            }
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
                    _ = store.addTab(url: URL(string: "https://www.google.com"), select: true)
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

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.tabs) { tab in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if store.selectedTabID == tab.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
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
                            store.select(tab.id)
                            isPresented = false
                        }

                        Button(role: .destructive) {
                            store.close(tab.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Close Tab")
                    }
                }
            }
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        _ = store.addTab(url: URL(string: "https://www.google.com"), select: true)
                        isPresented = false
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
