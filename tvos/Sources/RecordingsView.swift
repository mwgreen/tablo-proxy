import SwiftUI

/// Recordings: what's on the Tablo merged with what's archived on the proxy
/// host, viewable flat by date, rolled up by show, or alphabetically.
struct RecordingsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("recView") private var mode = "date"
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 30) {
                    Text("Recordings").font(.title2).bold()
                    Spacer()
                    Picker("View", selection: $mode) {
                        Text("By date").tag("date")
                        Text("Shows").tag("shows")
                        Text("A–Z").tag("az")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 560)
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            await store.refreshRecordings()
                            refreshing = false
                        }
                    } label: {
                        Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(refreshing)
                }
                .padding(.horizontal, 40)

                let items = store.mergedRecordings()
                if items.isEmpty {
                    Spacer()
                    Text(store.loaded ? "No recordings" : "Loading…").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        switch mode {
                        case "shows": showsSection
                        case "az": azSections(items)
                        default: dateRows(items)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(.top, 20)
            .navigationDestination(for: RecItem.self) { item in
                RecordingDetailView(itemId: item.id)
            }
            .navigationDestination(for: ShowGroup.self) { group in
                ShowEpisodesView(group: group)
            }
            .onAppear {
                // Like the web UI: opening the tab rescans the Tablo.
                Task { await store.refreshRecordings() }
            }
        }
    }

    // In-progress captures first, then newest first.
    private func dateRows(_ items: [RecItem]) -> some View {
        let sorted = items.sorted { a, b in
            if a.inProgress != b.inProgress { return a.inProgress }
            return AppStore.byDateDesc(a, b)
        }
        return ForEach(sorted) { item in
            NavigationLink(value: item) { RecRow(item: item) }
        }
    }

    private var showsSection: some View {
        ForEach(store.showGroups()) { group in
            NavigationLink(value: group) {
                HStack(spacing: 14) {
                    if group.anyLive { RecBadge() }
                    Text(group.title).font(.headline)
                    Spacer()
                    Text(groupCount(group)).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func groupCount(_ g: ShowGroup) -> String {
        var s = "\(g.count) episode\(g.count == 1 ? "" : "s")"
        if g.savedCount > 0 { s += "  ·  \(g.savedCount) saved" }
        return s
    }

    private func azSections(_ items: [RecItem]) -> some View {
        let sorted = items.sorted { a, b in
            let ka = a.sortKey, kb = b.sortKey
            if ka != kb { return ka < kb }
            return AppStore.byDateDesc(a, b)
        }
        var letters: [String] = []
        var byLetter: [String: [RecItem]] = [:]
        for it in sorted {
            let l = Fmt.letter(it.title)
            if byLetter[l] == nil { letters.append(l); byLetter[l] = [] }
            byLetter[l]?.append(it)
        }
        return ForEach(letters, id: \.self) { letter in
            Section(letter) {
                ForEach(byLetter[letter] ?? []) { item in
                    NavigationLink(value: item) { RecRow(item: item) }
                }
            }
        }
    }
}

/// Episodes of one show, newest first.
struct ShowEpisodesView: View {
    @EnvironmentObject var store: AppStore
    let group: ShowGroup

    var body: some View {
        let items = store.mergedRecordings()
            .filter { $0.sortKey == group.key }
            .sorted(by: AppStore.byDateDesc)
        List {
            ForEach(items) { item in
                NavigationLink(value: item) { RecRow(item: item) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(group.title)
    }
}

struct RecRow: View {
    @EnvironmentObject var store: AppStore
    let item: RecItem

    private var metaLine: String {
        var parts: [String] = []
        if !item.channel.isEmpty { parts.append(item.channel) }
        if let d = item.date { parts.append(Fmt.dateTime(d)) }
        let dur = item.effectiveDuration
        if dur > 0 { parts.append(Fmt.duration(dur)) }
        if let r = item.rec {
            if r.isPartial { parts.append("partial") }
            if r.state == "failed" { parts.append("failed") }
        }
        if let l = item.lib, l.size > 0 { parts.append(Fmt.size(l.size)) }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        let job = store.job(for: item.id)
        let dur = item.effectiveDuration
        let resume = store.resumePosition(for: item.id, duration: dur)

        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    if item.inProgress { RecBadge() }
                    Text(item.title).font(.headline).lineLimit(1)
                    if item.isSaved {
                        Badge("SAVED", .green)
                    } else if let j = job, j.isActive {
                        Badge(j.label, .blue)
                    } else if let j = job, j.status == "failed" {
                        Badge("SAVE FAILED", .orange)
                    }
                }
                if !item.episodeLine.isEmpty {
                    Text(item.episodeLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(metaLine).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if resume > 0 && dur > 0 {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Resume at \(Fmt.clock(resume))").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: min(1, resume / dur)).frame(width: 180).tint(.gray)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Full-screen detail with play / resume / stop / save / delete.
struct RecordingDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let itemId: String

    private enum DeleteKind: Identifiable {
        case tablo, local, both
        var id: Int { hashValue }
    }
    @State private var showDeleteChoice = false
    @State private var pendingDelete: DeleteKind?
    @State private var confirmStop = false

    var body: some View {
        if let item = store.mergedItem(itemId) {
            content(item)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "film").font(.largeTitle)
                Text("This recording is gone.").foregroundStyle(.secondary)
            }
        }
    }

    private func play(_ item: RecItem, startAt: Double?) {
        store.playRequest = PlayRequest(kind: .recording(id: item.id, startAt: startAt))
    }

    private func metaLines(_ item: RecItem) -> [String] {
        var lines: [String] = []
        var first: [String] = []
        if !item.channel.isEmpty { first.append(item.channel) }
        if let d = item.date { first.append(Fmt.dateTime(d)) }
        let dur = item.effectiveDuration
        if dur > 0 { first.append(Fmt.duration(dur)) }
        if !first.isEmpty { lines.append(first.joined(separator: "  ·  ")) }
        if let r = item.rec {
            if r.isInProgress { lines.append("Recording now") }
            else if r.isPartial { lines.append("Partial recording (\(Fmt.duration(r.recordedDuration)) of \(Fmt.duration(r.duration)) scheduled)") }
            else if r.state == "failed" { lines.append("The Tablo reported this recording as failed") }
        }
        if let l = item.lib {
            var s = "Saved on the proxy host"
            if l.size > 0 { s += " (\(Fmt.size(l.size)))" }
            if item.rec == nil { s += " — the Tablo copy has been deleted" }
            lines.append(s)
        }
        return lines
    }

    @ViewBuilder
    private func content(_ item: RecItem) -> some View {
        let job = store.job(for: item.id)
        let dur = item.effectiveDuration
        let resume = store.resumePosition(for: item.id, duration: dur)

        HStack(alignment: .top, spacing: 60) {
            thumbnail(item)
                .frame(width: 640, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    if item.inProgress { RecBadge() }
                    if item.isSaved { Badge("SAVED", .green) }
                    else if let j = job, j.isActive { Badge(j.label, .blue) }
                    else if let j = job, j.status == "failed" { Badge("SAVE FAILED", .orange) }
                }
                Text(item.title).font(.largeTitle).bold().lineLimit(2)
                if !item.episodeLine.isEmpty {
                    Text(item.episodeLine).font(.title3).foregroundStyle(.secondary)
                }
                ForEach(metaLines(item), id: \.self) { line in
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
                if let j = job, j.status == "failed", let e = j.error, !e.isEmpty {
                    Text("Save failed: \(e)").font(.callout).foregroundStyle(.orange)
                }
                if !item.synopsis.isEmpty {
                    Text(item.synopsis).font(.body).foregroundStyle(.secondary).lineLimit(6)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if item.inProgress, let r = item.rec, let start = r.startDate {
                        Button {
                            play(item, startAt: max(0, Date().timeIntervalSince(start) - 5))
                        } label: { Label("Watch live", systemImage: "dot.radiowaves.left.and.right") }
                    }
                    if resume > 0 {
                        Button {
                            play(item, startAt: resume)
                        } label: { Label("Resume at \(Fmt.clock(resume))", systemImage: "play.fill") }
                        Button {
                            play(item, startAt: 0)
                        } label: { Label("Play from beginning", systemImage: "backward.end.fill") }
                    } else {
                        Button {
                            play(item, startAt: nil)
                        } label: { Label(item.inProgress ? "Play from beginning" : "Play", systemImage: "play.fill") }
                    }
                    if item.inProgress {
                        Button(role: .destructive) {
                            confirmStop = true
                        } label: { Label("Stop recording (keep partial)", systemImage: "stop.fill") }
                    }
                    if item.rec != nil && !item.inProgress && !item.isSaved && !(job?.isActive ?? false) {
                        Button {
                            Task { await store.archive(item.id) }
                        } label: { Label("Save a copy on the proxy host", systemImage: "arrow.down.to.line") }
                    }
                    Button(role: .destructive) {
                        if item.rec != nil && item.lib != nil { showDeleteChoice = true }
                        else if item.lib != nil { pendingDelete = .local }
                        else { pendingDelete = .tablo }
                    } label: { Label("Delete…", systemImage: "trash") }
                }
                .padding(.top, 10)
            }
            Spacer()
        }
        .padding(60)
        .confirmationDialog("Delete which copy?", isPresented: $showDeleteChoice, titleVisibility: .visible) {
            Button("Delete from Tablo (keep saved copy)") { pendingDelete = .tablo }
            Button("Delete saved copy (keep on Tablo)", role: .destructive) { pendingDelete = .local }
            Button("Delete both", role: .destructive) { pendingDelete = .both }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete \(item.title)?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { kind in
            Button("Delete", role: .destructive) {
                Task {
                    switch kind {
                    case .tablo: await store.deleteRecording(item.id)
                    case .local: await store.deleteLibraryEntry(item.id)
                    case .both: await store.deleteBoth(item.id)
                    }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            switch kind {
            case .tablo:
                Text(item.lib != nil ? "The Tablo copy will be deleted. Your saved copy stays." : "This recording will be deleted from the Tablo.")
            case .local:
                Text(item.rec != nil ? "The saved copy will be deleted. The Tablo copy stays." : "This is the only copy.")
            case .both:
                Text("The recording will be deleted from the Tablo and from the proxy host.")
            }
        }
        .alert("Stop recording?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { Task { await store.stopRecording(item.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps what has been recorded so far and frees the tuner.")
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: RecItem) -> some View {
        if let lib = item.lib, lib.thumb != nil, let url = store.client.libraryThumbURL(lib.id) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.08)
            Image(systemName: "tv").font(.system(size: 80)).foregroundStyle(.secondary)
        }
    }
}
