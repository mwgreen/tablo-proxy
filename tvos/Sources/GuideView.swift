import SwiftUI

/// Which guide control has focus: a channel's label or one of its programs.
enum GuideFocus: Hashable {
    case label(Int)
    case cell(Int, String)
}

/// TV guide grid: one row per channel, a fixed 3-hour window across the
/// screen, paged with Earlier / Now / Later — or by moving past the first or
/// last program in a row. Selecting a program offers to watch the channel or
/// change its recording schedule.
struct GuideView: View {
    @EnvironmentObject var store: AppStore
    @State private var windowStart: Date = GuideView.defaultWindowStart()
    @State private var selection: GuideSelection?
    @State private var now = Date()
    @State private var refreshing = false
    @FocusState private var focus: GuideFocus?
    /// Focus before its latest change and when that change happened: a move
    /// command is reported after the focus engine has already acted on it.
    @State private var prevFocus: GuideFocus?
    @State private var focusChangedAt = Date.distantPast
    /// Index of the channel row at the top of the grid. The guide scrolls by
    /// whole rows itself; tvOS's own focus scrolling moves just enough to
    /// show the focused row, which leaves a half row at the top.
    @State private var topRow = 0
    @State private var gridHeight: CGFloat = 0

    /// How far one edge press moves the window.
    static let edgeStep: TimeInterval = 90 * 60

    static let windowHours: Double = 3
    static let pxPerMinute: CGFloat = 8
    static let labelWidth: CGFloat = 230
    static let rowHeight: CGFloat = 96
    static var gridWidth: CGFloat { CGFloat(windowHours * 60) * pxPerMinute }

    private var windowEnd: Date { windowStart.addingTimeInterval(GuideView.windowHours * 3600) }
    /// Programs that have already ended aren't shown, even inside the window.
    private var shownFrom: Date { max(windowStart, now) }

    /// Half-hour boundary at or before now: the guide never shows the past.
    static func defaultWindowStart(_ now: Date = Date()) -> Date {
        let t = now
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
                // The time bar sits above the scroll view rather than pinned
                // inside it: tvOS scrolls the focused row flush to the top of
                // the scroll view, which put half a row under a pinned header.
                timeHeader
                ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                            ForEach(store.visibleChannels) { ch in
                                GuideRow(channel: ch,
                                         airings: store.airings(for: ch.id),
                                         windowStart: windowStart,
                                         windowEnd: windowEnd,
                                         now: now,
                                         focus: $focus,
                                         onAiring: { a in selection = GuideSelection(channel: ch, airing: a) },
                                         onChannel: { store.playRequest = PlayRequest(kind: .channel(ch)) })
                                .id(ch.id)
                            }
                    }
                    .padding(.top, 8)
                }
                .clipped()
                .background(GeometryReader { g in
                    Color.clear.onAppear { gridHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in gridHeight = h }
                })
                .onChange(of: focus) { _, f in alignRows(to: f, proxy: proxy) }
                }
                .focusSection()
                .onMoveCommand(perform: pageAtEdge)
                .onChange(of: focus) { old, _ in
                    prevFocus = old
                    focusChangedAt = Date()
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        // A .task survives re-renders (it's tied to the view's identity). A
        // Timer.publish stored on the struct was rebuilt on every store
        // publish (tuners every 15s), restarting its 60s interval so it never
        // fired and the now-line froze.
        .task {
            while !Task.isCancelled {
                now = Date()
                // Wake on the minute so programs drop off as they end.
                let intoMinute = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                try? await Task.sleep(for: .seconds(60 - intoMinute + 0.2))
            }
        }
        // The Apple TV sleeps with the app open: the minute loop above was
        // suspended, so catch the clock up the moment we're back.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            now = Date()
        }
        .onChange(of: now) { _, _ in rollWindowForward() }
        .confirmationDialog(
            selection?.airing.showTitle ?? "",
            isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }),
            titleVisibility: .visible,
            presenting: selection
        ) { sel in
            Button("Watch \(sel.channel.label)") { play(sel.channel) }
            if store.playback != nil {
                Button("Watch \(sel.channel.label) in Picture in Picture") { play(sel.channel, pip: true) }
            }
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

    /// Moving left from a row's first program, or right from its last, pages
    /// the window 90 minutes and keeps focus in that row on the program at
    /// the edge that was crossed. Paging back stops at the default "now"
    /// window, so left from the first program there still reaches the
    /// channel label (tune in); Earlier goes further back.
    ///
    /// The move command arrives after the focus engine has handled it, so
    /// judge by what focus did: right at the edge leaves focus stuck on the
    /// last program; left at the edge carries it from the first program onto
    /// the channel label.
    private func pageAtEdge(_ dir: MoveCommandDirection) {
        // Let a focus change from this same press land first.
        DispatchQueue.main.async {
            let moved = Date().timeIntervalSince(focusChangedAt) < 0.25
            switch dir {
            case .right:
                guard !moved, case .cell(let chId, let airingId)? = focus,
                      isEdge(chId, airingId, first: false) else { return }
                let lastEnd = store.guide.values.compactMap { $0.last?.end }.max() ?? windowEnd
                guard lastEnd > windowEnd else { return }
                let anchor = windowEnd.addingTimeInterval(60)
                windowStart = windowStart.addingTimeInterval(GuideView.edgeStep)
                refocus(chId, at: anchor)
            case .left:
                let from: GuideFocus? = moved ? prevFocus : focus
                guard case .cell(let chId, let airingId)? = from,
                      isEdge(chId, airingId, first: true) else { return }
                // Only when focus left the program for its row's label (or
                // couldn't move at all).
                if moved, focus != .label(chId) { return }
                let floor = GuideView.defaultWindowStart(now)
                guard windowStart > floor else { return }
                let anchor = windowStart.addingTimeInterval(-60)
                windowStart = max(floor, windowStart.addingTimeInterval(-GuideView.edgeStep))
                refocus(chId, at: anchor)
            default:
                break
            }
        }
    }

    /// Keep the focused row on screen, scrolling in whole-row steps so the
    /// grid always starts with a complete row.
    private func alignRows(to f: GuideFocus?, proxy: ScrollViewProxy) {
        let chId: Int
        switch f {
        case .cell(let id, _)?: chId = id
        case .label(let id)?: chId = id
        default: return
        }
        let rows = store.visibleChannels
        guard let i = rows.firstIndex(where: { $0.id == chId }) else { return }
        let pitch = GuideView.rowHeight + 8
        let visible = max(1, Int((gridHeight - 8) / pitch))
        var top = topRow
        if i < top { top = i } else if i >= top + visible { top = i - visible + 1 }
        top = max(0, min(top, max(0, rows.count - visible)))
        topRow = top
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(rows[top].id, anchor: .top)
        }
    }

    /// Is this the first (or last) program visible in its row?
    private func isEdge(_ chId: Int, _ airingId: String, first: Bool) -> Bool {
        let row = store.airings(for: chId).filter { $0.end > shownFrom && $0.start < windowEnd }
        return (first ? row.first : row.last)?.id == airingId
    }

    /// The guide never shows the past: the window's start can't fall behind
    /// the current half-hour, so as time passes (or after a night asleep) it
    /// slides forward and old programs drop off the left. A window paged
    /// ahead into the future is left alone. Ended programs drop out of the
    /// grid; focus on one moves to what's on now.
    private func rollWindowForward() {
        let floor = GuideView.defaultWindowStart(now)
        if windowStart < floor { windowStart = floor }
        if case .cell(let chId, let airingId)? = focus {
            let a = store.airings(for: chId).first { $0.id == airingId }
            if a.map({ $0.end <= shownFrom }) ?? true { refocus(chId, at: shownFrom) }
        }
    }

    private func refocus(_ chId: Int, at t: Date) {
        let airings = store.airings(for: chId)
        let target = airings.first { $0.start <= t && $0.end > t }
            ?? airings.first { $0.end > shownFrom && $0.start < windowEnd }
        // After the grid re-renders with the new window.
        DispatchQueue.main.async { focus = target.map { .cell(chId, $0.id) } }
    }

    private func play(_ ch: Channel, pip: Bool = false) {
        // Let the dialog finish dismissing before presenting the player.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if pip { store.playInPip(PlayRequest(kind: .channel(ch))) }
            else { store.playRequest = PlayRequest(kind: .channel(ch)) }
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

    /// One focus section, so moving up from anywhere in the grid lands on
    /// these buttons first (not on the tab bar when the grid column happens
    /// to sit under it).
    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            focusDetails
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let floor = GuideView.defaultWindowStart(now)
                windowStart = max(floor, windowStart.addingTimeInterval(-GuideView.windowHours * 3600))
            } label: { Label("Earlier", systemImage: "chevron.left") }
            .disabled(windowStart <= GuideView.defaultWindowStart(now))
            Button("Now") { windowStart = GuideView.defaultWindowStart(now) }
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
        .focusSection()
    }

    /// One line about whatever has focus. A program shows just its detail —
    /// the episode ("Hawaii at Wyoming" under "College Football"), or its full
    /// title when there's no episode, since grid cells truncate titles. A
    /// channel label shows the same for what's on now. Otherwise the date
    /// and the window's time range. Channel, time and description are left
    /// to the grid and the program's Select dialog.
    @ViewBuilder
    private var focusDetails: some View {
        switch focus {
        case .cell(let chId, let airingId)?:
            if let a = store.airings(for: chId).first(where: { $0.id == airingId }) {
                detailLine(a)
            } else {
                dateDetails
            }
        case .label(let chId)?:
            if let a = store.currentAiring(for: chId, at: now) {
                detailLine(a)
            } else {
                dateDetails
            }
        default:
            dateDetails
        }
    }

    private func detailLine(_ a: GuideAiring) -> some View {
        let detail = (!a.episodeTitle.isEmpty && a.episodeTitle != a.showTitle) ? a.episodeTitle : a.showTitle
        return Text(detail).font(.title3).bold().lineLimit(1)
    }

    private var dateDetails: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(Fmt.dayLabel(windowStart)).font(.title3).bold()
            Text("\(Fmt.time(windowStart)) – \(Fmt.time(windowEnd))").font(.title3).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var timeHeader: some View {
        HStack(spacing: 0) {
            // The date lives here now; the header shows focused-program details.
            Text(Fmt.dayLabel(windowStart))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: GuideView.labelWidth + 12, alignment: .leading)
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
    var focus: FocusState<GuideFocus?>.Binding
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
        // Ended programs are left as a gap, so the grid never offers the past.
        for a in airings where a.end > max(windowStart, now) && a.start < windowEnd {
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
            .focused(focus, equals: .label(channel.id))

            Spacer().frame(width: 12)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(slots) { slot in
                        if let a = slot.airing {
                            GuideCell(airing: a, channel: channel, now: now) { onAiring(a) }
                                .focused(focus, equals: .cell(channel.id, a.id))
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
