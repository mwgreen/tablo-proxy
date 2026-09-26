import SwiftUI

struct LiveView: View {
    @EnvironmentObject var store: AppStore
    @State private var now = Date()

    private var tunerSummary: String {
        let inUse = store.tuners.filter { $0.inUse }.count
        guard !store.tuners.isEmpty else { return "" }
        return "\(inUse) of \(store.tuners.count) tuners in use"
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 30) {
                Text("Live TV").font(.title2).bold()
                Spacer()
                if !tunerSummary.isEmpty {
                    Text(tunerSummary).font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    store.favoritesOnly.toggle()
                } label: {
                    Label(store.favoritesOnly ? "Favorites" : "All channels",
                          systemImage: store.favoritesOnly ? "star.fill" : "star")
                }
            }
            .padding(.horizontal, 40)

            if store.favoritesOnly && store.favorites.isEmpty {
                Text("No favorites yet — hold Select on a channel to add one. Showing all channels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            List(store.visibleChannels) { ch in
                ChannelRow(channel: ch, now: now)
            }
            .listStyle(.plain)
        }
        .padding(.top, 20)
        // See GuideView: a stored Timer.publish is rebuilt on every re-render.
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject var store: AppStore
    let channel: Channel
    let now: Date

    private func progress(_ a: GuideAiring) -> Double {
        guard a.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(a.start) / a.duration))
    }

    var body: some View {
        let airing = store.currentAiring(for: channel.id, at: now)
        let recording = store.isChannelRecording(channel.id)
        let fav = store.favorites.contains(channel.id)

        Button {
            store.playRequest = PlayRequest(kind: .channel(channel))
        } label: {
            HStack(spacing: 28) {
                Text(channel.number)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(width: 130, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(channel.name).font(.headline)
                        if !channel.callSign.isEmpty && channel.callSign != channel.name {
                            Text(channel.callSign).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if fav {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        }
                        if recording { RecBadge() }
                    }
                    if let a = airing {
                        Text(a.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(Fmt.time(a.start)) – \(Fmt.time(a.end))" + (a.episodeInfo.isEmpty ? "" : "  ·  \(a.episodeInfo)"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("No guide data").font(.subheadline).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let a = airing {
                    ProgressView(value: progress(a))
                        .frame(width: 180)
                        .tint(.gray)
                }
            }
            .padding(.vertical, 6)
        }
        .contextMenu {
            Button {
                store.toggleFavorite(channel)
            } label: {
                Label(fav ? "Remove from favorites" : "Add to favorites", systemImage: fav ? "star.slash" : "star")
            }
            let capturing = recording ? store.inProgressRecording(on: channel) : nil
            ForEach(store.recordActions(showId: nil, airing: airing, channel: channel, capturing: capturing)) { action in
                Button(action.title, role: action.destructive ? ButtonRole.destructive : nil) {
                    Task { await action.perform() }
                }
            }
        }
    }
}
