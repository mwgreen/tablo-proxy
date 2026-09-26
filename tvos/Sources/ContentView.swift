import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live TV", systemImage: "tv") }
            GuideView()
                .tabItem { Label("Guide", systemImage: "calendar") }
            RecordingsView()
                .tabItem { Label("Recordings", systemImage: "film.stack") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .task { await store.loadAll() }
        .task { await store.tunerLoop() }
        .task { await store.libraryLoop() }
        .task { await store.guideLoop() }
        .overlay(alignment: .top) { ErrorBanner() }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay {
            if store.loading && !store.loaded {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Connecting to \(store.client.baseURL)…").foregroundStyle(.secondary)
                }
                .padding(50)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .fullScreenCover(item: $store.playRequest) { req in
            PlayerView(request: req)
                .environmentObject(store)
        }
    }
}
