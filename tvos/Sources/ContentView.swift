import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: ProxyClient
    @State private var playing: PlayRequest?

    var body: some View {
        TabView {
            LiveView(playing: $playing)
                .tabItem { Label("Live TV", systemImage: "tv") }
            RecordingsView(playing: $playing)
                .tabItem { Label("Recordings", systemImage: "film.stack") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .task { await client.refresh() }
        .fullScreenCover(item: $playing) { req in
            PlayerView(request: req)
        }
    }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let title: String
    let path: String      // proxy route that starts the stream
}

struct LiveView: View {
    @EnvironmentObject var client: ProxyClient
    @Binding var playing: PlayRequest?

    var body: some View {
        NavigationStack {
            List(client.channels) { ch in
                Button {
                    playing = PlayRequest(title: "\(ch.number) \(ch.name)", path: "/stream/hls/channel/\(ch.id)")
                } label: {
                    HStack {
                        Text(ch.number).font(.headline).frame(width: 120, alignment: .leading)
                        Text(ch.name)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Live TV")
            .overlay { if let e = client.lastError { ErrorBanner(text: e) } }
            .refreshable { await client.refresh() }
        }
    }
}

struct RecordingsView: View {
    @EnvironmentObject var client: ProxyClient
    @Binding var playing: PlayRequest?

    var body: some View {
        NavigationStack {
            List(client.recordings) { rec in
                Button {
                    playing = PlayRequest(title: rec.title, path: "/stream/hls/recording/\(rec.id)")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rec.title).font(.headline)
                            if rec.state == "recording" {
                                Text("REC").font(.caption).bold().padding(4).background(.red).cornerRadius(4)
                            }
                        }
                        if let ep = rec.episode, !ep.isEmpty {
                            Text(episodeLine(rec)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(metaLine(rec)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Recordings")
            .refreshable { await client.refresh() }
        }
    }

    private func episodeLine(_ r: Recording) -> String {
        if let s = r.seasonNumber, let e = r.episodeNumber { return "S\(s)E\(e): \(r.episode ?? "")" }
        return r.episode ?? ""
    }

    private func metaLine(_ r: Recording) -> String {
        var parts: [String] = []
        if let c = r.channel, !c.isEmpty { parts.append(c) }
        if let d = r.date, let date = ISO8601DateFormatter().date(from: d.count == 17 ? d.replacingOccurrences(of: "Z", with: ":00Z") : d) {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if let dur = r.duration, dur > 0 { parts.append("\(Int(dur / 60)) min") }
        return parts.joined(separator: " · ")
    }
}

struct SettingsView: View {
    @EnvironmentObject var client: ProxyClient
    @State private var draft = ""

    var body: some View {
        Form {
            Section("Proxy server") {
                TextField("http://host:port", text: $draft)
                    .onAppear { draft = client.baseURL }
                Button("Save & reload") {
                    client.baseURL = draft
                    Task { await client.refresh() }
                }
            }
            Section {
                Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).padding().background(.red.opacity(0.85)).cornerRadius(8).padding()
        }
    }
}
