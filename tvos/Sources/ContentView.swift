import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    /// Remembered across launches, so coming back lands on the same screen.
    @AppStorage("selectedTab") private var tab = "live"

    var body: some View {
        TabView(selection: $tab) {
            LiveView()
                .tabItem { Label("Live TV", systemImage: "tv") }
                .tag("live")
            GuideView()
                .tabItem { Label("Guide", systemImage: "calendar") }
                .tag("guide")
            RecordingsView()
                .tabItem { Label("Recordings", systemImage: "film.stack") }
                .tag("recordings")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag("settings")
        }
        .task {
            await store.loadAll()
            store.restoreSession()   // relaunch after tvOS closed the app
        }
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
        // Leaving the app: remember what was playing, then stop, so the
        // Tablo tuner and the proxy's transcode aren't held while nobody
        // watches. Coming back: pick up where we were. (UIKit notifications:
        // SwiftUI's scenePhase didn't report the background on tvOS here.)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            diag("didEnterBackground: saving + stopping")
            store.saveSession()
            store.stopPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            diag("willEnterForeground: restoring")
            store.restoreSession()
            Task {
                await store.refreshChannels()
                await store.refreshGuideIfStale()
            }
        }
    }
}
