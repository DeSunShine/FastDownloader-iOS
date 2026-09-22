import SwiftUI

struct BrowserView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        NavigationStack {
            Group {
                if let tab = store.currentTab {
                    ActiveBrowserTabView(tab: tab, store: store)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search or enter address", text: $address)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        store.navigate(address, in: tab)
                    }

                if tab.isLoading {
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
                .disabled(!tab.webView.canGoBack)

                Spacer()

                Button {
                    tab.webView.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!tab.webView.canGoForward)

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
                    if let url = tab.webView.url {
                        DownloadCapture.capture(
                            request: URLRequest(url: url),
                            from: tab.webView,
                            preferredFilename: nil
                        )
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(tab.webView.url == nil)

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
            }
            .font(.title3)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear {
            address = tab.urlString ?? ""
        }
        .onChange(of: tab.urlString) { _, newValue in
            address = newValue ?? ""
        }
        .sheet(isPresented: $showTabs) {
            TabSwitcherView(store: store, isPresented: $showTabs)
        }
    }
}

private struct TabSwitcherView: View {
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.tabs) { tab in
                    HStack {
                        Button {
                            store.select(tab.id)
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tab.title)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(tab.urlString ?? "New Tab")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            store.close(tab.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
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
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
