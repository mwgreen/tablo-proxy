import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

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
        // The mini player lives in the top-right corner, level with the tab
        // bar, so it costs the browse screens no space.
        // Inset to line up with the screens' content, which is padded 40pt
        // inside the safe area.
        .overlay(alignment: .topTrailing) { MiniPlayerView().padding(.trailing, 40) }
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
        .fullScreenCover(isPresented: $store.playerFullScreen) {
            if let ctl = store.playback {
                PlayerView(ctl: ctl)
                    .environmentObject(store)
            }
        }
        // Play/Pause while browsing controls the mini player.
        .onPlayPauseCommand {
            guard !store.playerFullScreen, let p = store.playback?.player else { return }
            if p.rate == 0 { p.play() } else { p.pause() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app: stop, so the Tablo tuner and the proxy's
            // transcode aren't held while nobody's watching.
            if phase == .background { store.stopPlayback() }
        }
    }
}
