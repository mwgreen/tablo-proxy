import SwiftUI
import AVKit

/// Per-second playback position, kept apart from PlaybackController so the
/// info panel can tick without re-rendering the whole player each second.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0       // absolute seconds into the recording / DVR window
    @Published var seekableEnd: Double = 0    // absolute
    @Published var isPlaying = false
}

/// Drives one AVPlayer against a proxy stream: starts and stops the transcode
/// session, keeps it alive, recovers when the proxy reaps it, seeks
/// server-side beyond what has been transcoded, and follows an in-progress
/// recording through the end of its capture.
@MainActor
final class PlaybackController: ObservableObject {
    enum Mode {
        case idle
        case liveChannel(Channel)
        /// An in-progress capture. `channel` is set when the user picked the
        /// channel (so we continue live when the capture ends) and nil when
        /// they picked the recording.
        case liveRecording(Recording, channel: Channel?)
        case recording(Recording)
        case local(LibraryEntry)
    }

    let player = AVPlayer()
    let clock = PlaybackClock()

    @Published private(set) var mode: Mode = .idle
    @Published var status: String? = "Starting stream…"
    @Published var error: String?
    @Published private(set) var title = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var synopsis = ""
    @Published private(set) var totalDuration: Double = 0
    @Published private(set) var serverOffset: Double = 0

    private(set) var sessionId: String?
    private(set) var playlistURL: URL?
    private weak var store: AppStore?
    private var gen = 0
    private var statusObs: NSKeyValueObservation?
    private var timeObserver: Any?
    private var loops: [Task<Void, Never>] = []

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
    }

    // MARK: State

    var isLive: Bool {
        switch mode {
        case .liveChannel, .liveRecording: return true
        default: return false
        }
    }

    var isLocal: Bool {
        if case .local = mode { return true }
        return false
    }

    var recordingId: String? {
        switch mode {
        case .liveRecording(let r, _), .recording(let r): return r.idString
        case .local(let l): return l.id
        default: return nil
        }
    }

    var channel: Channel? {
        switch mode {
        case .liveChannel(let c): return c
        case .liveRecording(_, let c): return c
        default: return nil
        }
    }

    var liveRecording: Recording? {
        if case .liveRecording(let r, _) = mode { return r }
        return nil
    }

    var absolutePosition: Double {
        let t = player.currentTime().seconds
        return serverOffset + (t.isFinite && t > 0 ? t : 0)
    }

    /// What the current item can seek within (relative to the item).
    var seekableRange: ClosedRange<Double>? {
        guard let r = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let s = r.start.seconds, e = r.end.seconds
        guard s.isFinite, e.isFinite, e > s else { return nil }
        return s...e
    }

    /// For an in-progress capture, how far the recording has got (wall clock).
    var liveEdge: Double? {
        guard case .liveRecording(let rec, _) = mode, let start = rec.startDate else { return nil }
        return max(0, Date().timeIntervalSince(start))
    }

    // MARK: Opening

    func open(_ req: PlayRequest, store: AppStore) async {
        self.store = store
        switch req.kind {
        case .channel(let ch):
            await openChannel(ch)
        case .recording(let id, let startAt):
            await openRecording(id: id, startAt: startAt)
        }
        startLoops()
    }

    func openChannel(_ ch: Channel) async {
        guard let store else { return }
        let airing = store.currentAiring(for: ch.id)
        title = "\(ch.number) · \(ch.name)"
        subtitle = airing?.displayTitle ?? ""
        synopsis = airing?.synopsis ?? ""
        if let rec = store.inProgressRecording(on: ch), let start = rec.startDate {
            // Being recorded: play the recording stream seeked to the live
            // edge so the viewer gets full DVR controls back to its start.
            mode = .liveRecording(rec, channel: ch)
            totalDuration = rec.duration
            let offset = max(0, Date().timeIntervalSince(start) - 5)
            await openSession(path: recordingPath(rec.id, offset: offset), offset: offset)
        } else {
            mode = .liveChannel(ch)
            totalDuration = 0
            await openSession(path: "/stream/hls/channel/\(ch.id)", offset: 0)
        }
    }

    func openRecording(id: String, startAt: Double?) async {
        guard let store, let item = store.mergedItem(id) else {
            fail("Recording not found")
            return
        }
        title = item.title
        subtitle = [item.episodeLine, item.channel].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        synopsis = item.synopsis

        if let lib = item.lib, !item.inProgress {
            mode = .local(lib)
            totalDuration = lib.duration
            let start = startAt ?? store.resumePosition(for: id, duration: lib.duration)
            openLocal(lib, at: start)
        } else if let rec = item.rec {
            if rec.isInProgress {
                mode = .liveRecording(rec, channel: nil)
                totalDuration = rec.duration
            } else {
                mode = .recording(rec)
                totalDuration = rec.effectiveDuration
            }
            let start = startAt ?? store.resumePosition(for: id, duration: totalDuration)
            await openSession(path: recordingPath(rec.id, offset: start), offset: start)
        } else {
            fail("Recording not found")
        }
    }

    private func recordingPath(_ id: Int, offset: Double) -> String {
        offset > 0 ? "/stream/hls/recording/\(id)?offset=\(Int(offset))" : "/stream/hls/recording/\(id)"
    }

    private func openSession(path: String, offset: Double) async {
        guard let store else { return }
        gen += 1
        let g = gen
        status = "Starting stream…"
        error = nil
        statusObs = nil
        player.pause()
        releaseSession()
        do {
            let s = try await store.client.startStream(path: path)
            guard g == gen else {
                await store.client.stopSession(s.sessionId)
                return
            }
            sessionId = s.sessionId
            playlistURL = s.url
            serverOffset = offset
            load(url: s.url)
        } catch {
            guard g == gen else { return }
            fail("Couldn't start the stream: \(error.localizedDescription)")
        }
    }

    private func openLocal(_ lib: LibraryEntry, at start: Double) {
        gen += 1
        releaseSession()
        serverOffset = 0
        guard let url = store?.client.libraryVideoURL(lib.id) else {
            fail("The proxy address is not a valid URL")
            return
        }
        error = nil
        status = "Loading saved recording…"
        load(url: url, seekTo: start)
    }

    private func load(url: URL, seekTo: Double? = nil) {
        let item = AVPlayerItem(url: url)
        item.externalMetadata = metadataItems()
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let st = item.status
            let msg = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(st, message: msg) }
        }
        player.replaceCurrentItem(with: item)
        if let seekTo, seekTo > 0 {
            player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600))
        }
        player.play()
        status = "Buffering…"
    }

    private func itemStatusChanged(_ st: AVPlayerItem.Status, message: String?) {
        switch st {
        case .readyToPlay:
            status = nil
        case .failed:
            fail("Playback failed: \(message ?? "unknown error")")
        default:
            break
        }
    }

    private func fail(_ message: String) {
        error = message
        status = nil
    }

    /// Stop the previous proxy transcode session. Without this every stream
    /// switch leaves an ffmpeg running (and a live channel holds its Tablo
    /// tuner) until the proxy's 5-minute reaper fires.
    private func releaseSession() {
        let sid = sessionId
        sessionId = nil
        playlistURL = nil
        if let sid, let store {
            Task { await store.client.stopSession(sid) }
        }
    }

    private func metadataItems() -> [AVMetadataItem] {
        func make(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        return [
            make(.commonIdentifierTitle, title),
            make(.iTunesMetadataTrackSubTitle, subtitle),
            make(.commonIdentifierDescription, synopsis),
        ].compactMap { $0 }
    }

    // MARK: Seeking

    /// Seek to an absolute position. Within the transcoded range this is a
    /// native seek; beyond it the proxy restarts the transcode at the offset.
    func seek(toAbsolute pos: Double) async {
        let target = max(0, pos)
        switch mode {
        case .idle:
            return
        case .local:
            _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            player.play()
        default:
            let rel = target - serverOffset
            if let r = seekableRange, rel >= r.lowerBound, rel <= r.upperBound - 1 {
                _ = await player.seek(to: CMTime(seconds: rel, preferredTimescale: 600))
                player.play()
                return
            }
            await serverSeek(to: target)
        }
    }

    private func serverSeek(to target: Double) async {
        guard let store, let sid = sessionId else { return }
        gen += 1
        let g = gen
        status = "Seeking to \(Fmt.clock(target))…"
        // The old playlist disappears while the proxy restarts ffmpeg; drop
        // the observer so its failure isn't reported as ours.
        statusObs = nil
        player.pause()
        do {
            let r = try await store.client.seek(session: sid, offset: target)
            guard g == gen else { return }
            serverOffset = r.startOffset
            playlistURL = r.url
            load(url: r.url)
        } catch {
            guard g == gen else { return }
            status = nil
            player.play()
            store.showToast("Seek failed: \(error.localizedDescription)")
        }
    }

    func goLive() async {
        switch mode {
        case .liveChannel:
            if let r = seekableRange {
                _ = await player.seek(to: CMTime(seconds: r.upperBound, preferredTimescale: 600))
            }
            player.play()
        case .liveRecording:
            guard let edge = liveEdge else { return }
            // If the transcode has caught up with the capture, the end of the
            // seekable range is the live edge; otherwise restart there.
            if let r = seekableRange, serverOffset + r.upperBound >= edge - 20 {
                _ = await player.seek(to: CMTime(seconds: r.upperBound, preferredTimescale: 600))
                player.play()
            } else {
                await seek(toAbsolute: max(0, edge - 8))
            }
        default:
            break
        }
    }

    // MARK: Lifecycle loops

    private func startLoops() {
        stopLoops()
        loops.append(Task { [weak self] in await self?.keepAliveLoop() })
        loops.append(Task { [weak self] in await self?.resumeLoop() })
        loops.append(Task { [weak self] in await self?.liveStatusLoop() })
    }

    private func stopLoops() {
        for t in loops { t.cancel() }
        loops.removeAll()
    }

    /// The proxy reaps sessions after 5 idle minutes (a paused player stops
    /// fetching segments). A HEAD on the playlist keeps ours alive and, on a
    /// 404, tells us to reopen at the current position.
    private func keepAliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            await checkSession()
        }
    }

    func checkSession() async {
        guard let store, let url = playlistURL, !isLocal else { return }
        if let alive = await store.client.playlistAlive(url), !alive {
            await recoverExpiredSession()
        }
    }

    private func recoverExpiredSession() async {
        let pos = absolutePosition
        switch mode {
        case .liveChannel(let ch):
            await openSession(path: "/stream/hls/channel/\(ch.id)", offset: 0)
        case .liveRecording(let rec, _), .recording(let rec):
            await openSession(path: recordingPath(rec.id, offset: pos), offset: pos)
        default:
            break
        }
    }

    private func resumeLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            saveResume()
        }
    }

    private func saveResume() {
        guard let id = recordingId, let store else { return }
        store.saveResume(id, position: absolutePosition)
    }

    /// While watching an in-progress recording, poll its capture state so the
    /// player reacts when the capture ends — on schedule, stopped from this
    /// app, or stopped elsewhere.
    private func liveStatusLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
            guard let store, let rec = liveRecording else { continue }
            guard let s = try? await store.client.recordingStatus(rec.id) else { continue }
            if !s.state.isEmpty && s.state != "recording" {
                await endLiveWatch(state: s.state, recordedDuration: s.recordedDuration)
            }
        }
    }

    /// The capture behind the stream has ended. If the viewer picked the
    /// channel and is near the live edge, they're watching TV: reopen the
    /// direct channel stream so playback continues into the next show.
    /// Otherwise the player becomes plain playback of what was captured.
    func endLiveWatch(state: String?, recordedDuration: Double?) async {
        guard case .liveRecording(let rec, let ch) = mode, let store else { return }
        store.markRecordingEnded(rec.idString, state: state ?? "finished", recordedDuration: recordedDuration)

        var nearLive = false
        if let r = seekableRange {
            let t = player.currentTime().seconds
            nearLive = (r.upperBound - (t.isFinite ? t : 0)) < 60
        }
        if let ch, nearLive {
            store.showToast("Recording ended — continuing live")
            await openChannel(ch)
            return
        }
        mode = .recording(rec)
        if let rd = recordedDuration, rd > 0 {
            totalDuration = rd
        } else {
            totalDuration = max(rec.duration, serverOffset + (seekableRange?.upperBound ?? 0))
        }
        store.showToast("Recording ended")
    }

    /// Stop the capture we're watching (keeps the partial).
    func stopCapture() async {
        guard let store, let rec = liveRecording else { return }
        await store.stopRecording(rec.idString)
        await endLiveWatch(state: "finished", recordedDuration: nil)
    }

    private func tick() {
        clock.position = absolutePosition
        clock.seekableEnd = serverOffset + (seekableRange?.upperBound ?? 0)
        clock.isPlaying = player.timeControlStatus == .playing
    }

    func teardown() {
        gen += 1
        saveResume()
        stopLoops()
        statusObs = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        releaseSession()
        mode = .idle
    }
}

// MARK: - SwiftUI

struct PlayerView: View {
    let request: PlayRequest
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ctl = PlaybackController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContainer(ctl: ctl, store: store)
                .ignoresSafeArea()
            if let err = ctl.error {
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
                    Text(err).multilineTextAlignment(.center).frame(maxWidth: 900)
                    HStack(spacing: 30) {
                        Button("Try again") { Task { await ctl.open(request, store: store) } }
                        Button("Close") { dismiss() }
                    }
                }
                .padding(60)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            } else if let s = ctl.status {
                VStack(spacing: 20) {
                    ProgressView()
                    Text(s).foregroundStyle(.secondary)
                    if !ctl.title.isEmpty { Text(ctl.title).font(.headline) }
                }
                .padding(40)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .task { await ctl.open(request, store: store) }
        .onDisappear { ctl.teardown() }
        .onExitCommand { dismiss() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background: the proxy may have reaped the
            // session while we weren't fetching segments.
            if phase == .active { Task { await ctl.checkSession() } }
        }
    }
}

/// The system player (native transport bar, scrubbing, skip) with our
/// record / jump-to menus and a swipe-down info panel.
struct PlayerContainer: UIViewControllerRepresentable {
    @ObservedObject var ctl: PlaybackController
    @ObservedObject var store: AppStore

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = ctl.player
        vc.playbackControlsIncludeInfoViews = true
        vc.requiresLinearPlayback = false
        let info = UIHostingController(rootView: InfoPanelView(ctl: ctl, store: store))
        info.title = "Info"
        info.preferredContentSize = CGSize(width: 1920, height: 380)
        vc.customInfoViewControllers = [info]
        context.coordinator.apply(to: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.apply(to: vc)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(ctl: ctl, store: store)
    }

    @MainActor
    final class Coordinator {
        let ctl: PlaybackController
        let store: AppStore
        private var signature = ""

        init(ctl: PlaybackController, store: AppStore) {
            self.ctl = ctl
            self.store = store
        }

        /// Rebuild the transport bar menus only when their content changed;
        /// replacing them while open would dismiss the menu.
        func apply(to vc: AVPlayerViewController) {
            let (items, sig) = buildMenu()
            guard sig != signature else { return }
            signature = sig
            vc.transportBarCustomMenuItems = items
            vc.contextualActions = buildContextual()
        }

        private func buildMenu() -> ([UIMenuElement], String) {
            var items: [UIMenuElement] = []
            var sig: [String] = []

            // Record menu for the channel being watched
            if let ch = ctl.channel {
                let airing = store.currentAiring(for: ch.id)
                let capturing: Recording? = store.isChannelRecording(ch.id)
                    ? (ctl.liveRecording ?? store.inProgressRecording(on: ch)) : nil
                let actions = store.recordActions(showId: nil, airing: airing, channel: ch, capturing: capturing)
                var children: [UIMenuElement] = actions.map { a in
                    UIAction(title: a.title, attributes: a.destructive ? [.destructive] : []) { _ in
                        Task { @MainActor in await a.perform() }
                    }
                }
                if children.isEmpty {
                    children = [UIAction(title: "No guide data for this channel", attributes: [.disabled]) { _ in }]
                }
                let mark = airing.map { store.recordMark(for: $0, on: ch) } ?? AppStore.RecordMark.notScheduled
                let recording = capturing != nil || mark == .recordingNow
                let title = recording ? "Recording" : (mark == .scheduled ? "Scheduled" : "Record")
                items.append(UIMenu(title: title,
                                    image: UIImage(systemName: recording ? "record.circle.fill" : "record.circle"),
                                    children: children))
                sig.append("rec:\(title):" + actions.map { $0.id }.joined(separator: ","))
            } else if ctl.liveRecording != nil {
                let stop = UIAction(title: "Stop recording (keep partial)", attributes: [.destructive]) { [ctl] _ in
                    Task { @MainActor in await ctl.stopCapture() }
                }
                items.append(UIMenu(title: "Recording", image: UIImage(systemName: "record.circle.fill"), children: [stop]))
                sig.append("liverec")
            }

            // Jump-to menu: the transport bar can only scrub what's been
            // transcoded so far; these restart the transcode at a point.
            if !ctl.isLocal, ctl.recordingId != nil {
                let total = ctl.totalDuration
                var limit = total
                if let edge = ctl.liveEdge { limit = total > 0 ? min(total, edge) : edge }
                if limit > 120 {
                    var children: [UIMenuElement] = [
                        UIAction(title: "Start over", image: UIImage(systemName: "backward.end")) { [ctl] _ in
                            Task { @MainActor in await ctl.seek(toAbsolute: 0) }
                        },
                    ]
                    let step = jumpStep(limit)
                    var t = step
                    while t < limit - 60 {
                        let target = t
                        children.append(UIAction(title: Fmt.clock(target)) { [ctl] _ in
                            Task { @MainActor in await ctl.seek(toAbsolute: target) }
                        })
                        t += step
                    }
                    items.append(UIMenu(title: "Jump to", image: UIImage(systemName: "clock.arrow.circlepath"), children: children))
                    sig.append("jump:\(children.count)")
                }
            }
            return (items, sig.joined(separator: "|"))
        }

        private func jumpStep(_ limit: Double) -> Double {
            let raw = limit / 12
            let steps: [Double] = [300, 600, 900, 1200, 1800, 3600]
            return steps.first { $0 >= raw } ?? 3600
        }

        private func buildContextual() -> [UIAction] {
            guard ctl.isLive else { return [] }
            return [
                UIAction(title: "Go Live", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { [ctl] _ in
                    Task { @MainActor in await ctl.goLive() }
                },
            ]
        }
    }
}

/// Swipe-down panel: what's playing, where we are, and the source.
struct InfoPanelView: View {
    @ObservedObject var ctl: PlaybackController
    @ObservedObject var store: AppStore
    @ObservedObject var clock: PlaybackClock

    init(ctl: PlaybackController, store: AppStore) {
        self.ctl = ctl
        self.store = store
        _clock = ObservedObject(wrappedValue: ctl.clock)
    }

    private var sourceLabel: String {
        switch ctl.mode {
        case .idle: return ""
        case .liveChannel: return "Live from the Tablo tuner"
        case .liveRecording: return "Recording in progress on the Tablo"
        case .recording: return "Tablo recording"
        case .local: return "Saved copy on the proxy host"
        }
    }

    private var positionLine: String {
        switch ctl.mode {
        case .liveChannel:
            let behind = clock.seekableEnd - clock.position
            return behind > 15 ? "\(Fmt.clock(behind)) behind live" : "At the live edge"
        case .liveRecording:
            var s = Fmt.clock(clock.position)
            if let edge = ctl.liveEdge {
                let behind = edge - clock.position
                s += behind > 15 ? "  ·  \(Fmt.clock(behind)) behind live" : "  ·  live"
            }
            if ctl.totalDuration > 0 { s += "  ·  scheduled \(Fmt.duration(ctl.totalDuration))" }
            return s
        case .recording, .local:
            let total = ctl.totalDuration
            return total > 0 ? "\(Fmt.clock(clock.position)) / \(Fmt.clock(total))" : Fmt.clock(clock.position)
        case .idle:
            return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if ctl.isLive { Badge("LIVE", .red) }
                    if ctl.liveRecording != nil { Badge("RECORDING", .red) }
                    if ctl.isLocal { Badge("SAVED", .green) }
                    Text(ctl.title).font(.title2).bold()
                }
                if !ctl.subtitle.isEmpty {
                    Text(ctl.subtitle).font(.headline).foregroundStyle(.secondary)
                }
                if !ctl.synopsis.isEmpty {
                    Text(ctl.synopsis).font(.body).foregroundStyle(.secondary).lineLimit(5)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Text(positionLine).font(.title3.monospacedDigit())
                Text(sourceLabel).font(.callout).foregroundStyle(.secondary)
                if let ch = ctl.channel, let a = store.currentAiring(for: ch.id) {
                    Text("\(Fmt.time(a.start)) – \(Fmt.time(a.end))").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 30)
    }
}
