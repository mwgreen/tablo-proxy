import SwiftUI

/// TV guide grid: one row per channel, a fixed 3-hour window across the
/// screen, paged with Earlier / Now / Later. Selecting a program offers to
/// watch the channel or change its recording schedule.
struct GuideView: View {
    @EnvironmentObject var store: AppStore
    @State private var windowStart: Date = GuideView.defaultWindowStart()
    @State private var selection: GuideSelection?
    @State private var now = Date()
    @State private var refreshing = false
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    static let windowHours: Double = 3
    static let pxPerMinute: CGFloat = 8
    static let labelWidth: CGFloat = 230
    static let rowHeight: CGFloat = 96
    static var gridWidth: CGFloat { CGFloat(windowHours * 60) * pxPerMinute }

    private var windowEnd: Date { windowStart.addingTimeInterval(GuideView.windowHours * 3600) }

    /// Half-hour boundary at or before 30 minutes ago, like the web guide.
    static func defaultWindowStart(_ now: Date = Date()) -> Date {
        let t = now.addingTimeInterval(-30 * 60)
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: t)
        comps.minute = (comps.minute ?? 0) < 30 ? 0 : 30
        comps.second = 0
        return Calendar.current.date(from: comps) ?? t
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if store.guide.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Text(store.loaded ? "No guide data yet" : "Loading…").font(.title3)
                    if store.loaded {
                        Text("The proxy fetches the guide from Tablo's cloud on startup; try Refresh guide.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(store.visibleChannels) { ch in
                                GuideRow(channel: ch,
                                         airings: store.airings(for: ch.id),
                                         windowStart: windowStart,
                                         windowEnd: windowEnd,
                                         now: now,
                                         onAiring: { a in selection = GuideSelection(channel: ch, airing: a) },
                                         onChannel: { store.playRequest = PlayRequest(kind: .channel(ch)) })
                            }
                        } header: {
                            timeHeader
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .onReceive(tick) { now = $0 }
        .confirmationDialog(
            selection?.airing.showTitle ?? "",
            isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }),
            titleVisibility: .visible,
            presenting: selection
        ) { sel in
            Button("Watch \(sel.channel.label)") { play(sel.channel) }
            let capturing = sel.airing.isOn(at: now) && store.isChannelRecording(sel.channel.id)
                ? store.inProgressRecording(on: sel.channel) : nil
            ForEach(store.recordActions(showId: nil, airing: sel.airing, channel: sel.channel, capturing: capturing)) { action in
                Button(action.title, role: action.destructive ? ButtonRole.destructive : nil) {
                    Task { await action.perform() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { sel in
            Text(dialogMessage(sel))
        }
    }

    private func play(_ ch: Channel) {
        // Let the dialog finish dismissing before presenting the player.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            store.playRequest = PlayRequest(kind: .channel(ch))
        }
    }

    private func dialogMessage(_ sel: GuideSelection) -> String {
        let a = sel.airing
        var lines: [String] = []
        var when = "\(sel.channel.label)  ·  \(Fmt.time(a.start)) – \(Fmt.time(a.end))"
        if !a.episodeInfo.isEmpty { when += "  ·  \(a.episodeInfo)" }
        lines.append(when)
        if !a.episodeTitle.isEmpty && a.episodeTitle != a.showTitle { lines.append(a.episodeTitle) }
        if !a.synopsis.isEmpty { lines.append(a.synopsis) }
        switch store.recordMark(for: a, on: sel.channel, now: now) {
        case .recordingNow: lines.append("Recording now")
        case .scheduled: lines.append("Scheduled to record")
        case .skipped: lines.append("Series scheduled, but Tablo is skipping this airing (duplicate or conflict)")
        case .notScheduled: break
        }
        return lines.joined(separator: "\n")
    }

    private var header: some View {
        HStack(spacing: 24) {
            Text(Fmt.dayLabel(windowStart)).font(.title2).bold()
            Text("\(Fmt.time(windowStart)) – \(Fmt.time(windowEnd))").font(.title3).foregroundStyle(.secondary)
            Spacer()
            Button {
                windowStart = windowStart.addingTimeInterval(-GuideView.windowHours * 3600)
            } label: { Label("Earlier", systemImage: "chevron.left") }
            Button("Now") { windowStart = GuideView.defaultWindowStart() }
            Button {
                windowStart = windowStart.addingTimeInterval(GuideView.windowHours * 3600)
            } label: { Label("Later", systemImage: "chevron.right") }
            Button {
                guard !refreshing else { return }
                refreshing = true
                Task {
                    await store.refreshGuide(rescan: true)
                    refreshing = false
                }
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh guide", systemImage: "arrow.clockwise")
            }
            .disabled(refreshing)
        }
    }

    private var timeHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GuideView.labelWidth + 12)
            ForEach(0..<Int(GuideView.windowHours * 2), id: \.self) { i in
                Text(Fmt.time(windowStart.addingTimeInterval(Double(i) * 1800)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30 * GuideView.pxPerMinute, alignment: .leading)
            }
        }
        .frame(height: 36)
        .background(Color.black.opacity(0.85))
    }
}

struct GuideSelection {
    let channel: Channel
    let airing: GuideAiring
}

struct GuideRow: View {
    @EnvironmentObject var store: AppStore
    let channel: Channel
    let airings: [GuideAiring]
    let windowStart: Date
    let windowEnd: Date
    let now: Date
    let onAiring: (GuideAiring) -> Void
    let onChannel: () -> Void

    private struct Slot: Identifiable {
        let id: String
        let airing: GuideAiring?
        let width: CGFloat
    }

    /// Lay the window out left to right: a gap, then a program, then a gap…
    /// so the row is a plain HStack the focus engine can walk.
    private var slots: [Slot] {
        var out: [Slot] = []
        var cursor = windowStart
        let px = GuideView.pxPerMinute
        for a in airings where a.end > windowStart && a.start < windowEnd {
            let visStart = max(a.start, cursor)
            let visEnd = min(a.end, windowEnd)
            guard visEnd > visStart else { continue }
            if visStart > cursor {
                out.append(Slot(id: "gap-\(cursor.timeIntervalSince1970)", airing: nil,
                                width: CGFloat(visStart.timeIntervalSince(cursor) / 60) * px))
            }
            out.append(Slot(id: a.id, airing: a, width: CGFloat(visEnd.timeIntervalSince(visStart) / 60) * px))
            cursor = visEnd
        }
        if cursor < windowEnd {
            out.append(Slot(id: "gap-end", airing: nil, width: CGFloat(windowEnd.timeIntervalSince(cursor) / 60) * px))
        }
        return out
    }

    private var nowX: CGFloat? {
        guard now >= windowStart, now < windowEnd else { return nil }
        return CGFloat(now.timeIntervalSince(windowStart) / 60) * GuideView.pxPerMinute
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onChannel) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(channel.number).font(.headline.monospacedDigit())
                        if store.isChannelRecording(channel.id) { RecBadge() }
                    }
                    Text(channel.name).font(.subheadline).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(width: GuideView.labelWidth, height: GuideView.rowHeight, alignment: .leading)
            }
            .buttonStyle(GuideCellStyle(kind: .channel))

            Spacer().frame(width: 12)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(slots) { slot in
                        if let a = slot.airing {
                            GuideCell(airing: a, channel: channel, now: now) { onAiring(a) }
                                .frame(width: slot.width, height: GuideView.rowHeight)
                        } else {
                            Color.clear.frame(width: slot.width, height: GuideView.rowHeight)
                        }
                    }
                }
                if let x = nowX {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 3, height: GuideView.rowHeight)
                        .offset(x: x)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: GuideView.gridWidth, height: GuideView.rowHeight, alignment: .leading)
            .clipped()
        }
    }
}

struct GuideCell: View {
    @EnvironmentObject var store: AppStore
    let airing: GuideAiring
    let channel: Channel
    let now: Date
    let action: () -> Void

    var body: some View {
        let isOn = airing.isOn(at: now)
        let mark = store.recordMark(for: airing, on: channel, now: now)

        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(airing.showTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    RecordDot(mark: mark).font(.caption)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Text(Fmt.time(airing.start)).font(.caption2)
                    if !airing.episodeInfo.isEmpty {
                        Text(airing.episodeInfo).font(.caption2)
                    }
                }
                .opacity(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(GuideCellStyle(kind: isOn ? .onNow : .program))
    }
}
