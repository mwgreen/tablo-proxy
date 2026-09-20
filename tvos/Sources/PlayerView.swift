import SwiftUI
import AVKit

// Starts a proxy transcode session, plays its HLS playlist with the system
// player (native trick-play on the Siri remote), keeps the session alive while
// open and stops it on dismiss.
struct PlayerView: View {
    let request: PlayRequest
    @EnvironmentObject var client: ProxyClient
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var sessionId: String?
    @State private var playlist: URL?
    @State private var status = "Starting stream…"
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 20) {
                    if !failed { ProgressView() }
                    Text(status).foregroundStyle(.secondary)
                    if failed { Button("Close") { dismiss() } }
                }
            }
        }
        .task { await start() }
        .task { await keepAliveLoop() }
        .onDisappear { Task { await teardown() } }
    }

    private func start() async {
        do {
            let (url, sid) = try await client.startStream(path: request.path)
            sessionId = sid
            playlist = url
            let p = AVPlayer(url: url)
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            p.play()
        } catch {
            status = "Failed: \(error.localizedDescription)"
            failed = true
        }
    }

    private func keepAliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if let playlist { await client.keepAlive(playlist: playlist) }
        }
    }

    private func teardown() async {
        player?.pause()
        player = nil
        if let sessionId { await client.stopSession(sessionId) }
    }
}
