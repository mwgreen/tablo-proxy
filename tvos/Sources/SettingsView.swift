import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft = ""
    @State private var refreshingGuide = false

    private var build: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func tunerLabel(_ t: Tuner, index: Int) -> String {
        guard t.inUse else { return "Tuner \(index + 1): idle" }
        let chName: String = {
            guard let path = t.channel, let id = Int(path.split(separator: "/").last ?? ""),
                  let ch = store.channel(id: id) else { return t.channel ?? "unknown channel" }
            return ch.label
        }()
        return "Tuner \(index + 1): \(t.recording ? "recording" : "watching") \(chName)"
    }

    var body: some View {
        Form {
            Section("Proxy server") {
                TextField("http://host:port", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onAppear { draft = store.client.baseURL }
                Button("Save & reconnect") {
                    var u = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !u.isEmpty && !u.lowercased().hasPrefix("http://") && !u.lowercased().hasPrefix("https://") {
                        u = "http://" + u
                    }
                    store.client.baseURL = u.isEmpty ? ProxyClient.defaultBaseURL : u
                    draft = store.client.baseURL
                    Task { await store.loadAll() }
                }
                if let e = store.lastError {
                    Text(e).foregroundStyle(.red)
                } else if store.loaded {
                    Text("Connected · \(store.channels.count) channels · \(store.recordings.count) recordings")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Channels") {
                Toggle("Show only favorite channels", isOn: $store.favoritesOnly)
                Text(store.favorites.isEmpty
                     ? "No favorites yet. Hold Select on a channel in Live TV to mark one."
                     : "\(store.favorites.count) favorite channel\(store.favorites.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            Section("Guide") {
                Button(refreshingGuide ? "Refreshing…" : "Refresh guide from Tablo") {
                    guard !refreshingGuide else { return }
                    refreshingGuide = true
                    Task {
                        await store.refreshGuide(rescan: true)
                        refreshingGuide = false
                    }
                }
                .disabled(refreshingGuide)
                if let at = store.guideLoadedAt {
                    Text("Guide loaded \(Fmt.dateTime(at)) · \(store.guide.count) channels · \(store.seriesIndex.count) series")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tuners") {
                if store.tuners.isEmpty {
                    Text("No tuner status").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.tuners.enumerated()), id: \.offset) { i, t in
                        Text(tunerLabel(t, index: i))
                    }
                }
            }

            Section("Archive") {
                Text("\(store.library.count) recordings saved on the proxy host").foregroundStyle(.secondary)
                ForEach(store.archiveJobs.filter { $0.status != "done" }) { job in
                    HStack {
                        Text(job.title + (job.episode.isEmpty ? "" : " – \(job.episode)")).lineLimit(1)
                        Spacer()
                        Text(job.label).foregroundStyle(job.status == "failed" ? Color.orange : Color.secondary)
                    }
                }
            }

            Section("Playback") {
                Button("Clear all resume positions") { store.clearAllResumePositions() }
            }

            Section("About") {
                Text("Tablo for Apple TV · build \(build)").foregroundStyle(.secondary)
                Text("Plays live TV and recordings through tablo-proxy. Hold Select on a channel or program for recording options; swipe down in the player for details and Jump to.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
