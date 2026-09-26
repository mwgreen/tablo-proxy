import Foundation
import SwiftUI

/// One row of the Recordings screen: a Tablo recording, its local archived
/// copy, or both. Keyed by the Tablo recording id (the local copy keeps the id
/// after the Tablo copy is deleted, so resume positions carry over).
struct RecItem: Identifiable, Hashable {
    let id: String
    let rec: Recording?
    let lib: LibraryEntry?

    var title: String { rec?.title ?? lib?.title ?? "Unknown" }
    var episode: String { rec?.episode ?? lib?.episode ?? "" }
    var episodeLine: String { rec?.episodeLine ?? lib?.episodeLine ?? "" }
    var channel: String { rec?.channel ?? lib?.channel ?? "" }
    var synopsis: String {
        let s = rec?.synopsis ?? ""
        return s.isEmpty ? (lib?.synopsis ?? "") : s
    }
    var date: Date? { Fmt.date(rec?.date ?? lib?.date) }
    var inProgress: Bool { rec?.isInProgress ?? false }
    var isSaved: Bool { lib != nil }
    /// Prefer the local MP4 (instant native seek, no transcode) unless the
    /// capture is still in progress — live viewing needs the Tablo's growing stream.
    var playsLocally: Bool { lib != nil && !inProgress }
    var effectiveDuration: Double {
        if let r = rec { return r.effectiveDuration }
        return lib?.duration ?? 0
    }
    var sortKey: String { Fmt.titleKey(title) }
}

struct ShowGroup: Identifiable, Hashable {
    let key: String
    let title: String
    let count: Int
    let savedCount: Int
    let anyLive: Bool
    var id: String { key }
}

/// A menu entry for the record menus (guide, channel list, player).
struct RecordAction: Identifiable {
    let id: String
    let title: String
    let destructive: Bool
    let perform: @MainActor () async -> Void
}

struct PlayRequest: Identifiable {
    enum Kind {
        case channel(Channel)
        case recording(id: String, startAt: Double?)
        /// An in-progress recording opened at its live edge. The player works
        /// out where the edge is (from the capture's actual start), so callers
        /// don't compute an offset from the airing's scheduled start.
        case recordingLive(id: String)
    }
    let id = UUID()
    let kind: Kind
}

@MainActor
final class AppStore: ObservableObject {
    let client = ProxyClient()

    @Published var channels: [Channel] = []
    @Published var recordings: [Recording] = []
    @Published var guide: [Int: [GuideAiring]] = [:]
    @Published var favorites: Set<Int> = []
    @Published var favoritesOnly: Bool {
        didSet { UserDefaults.standard.set(favoritesOnly, forKey: "favoritesOnly") }
    }
    @Published var seriesIndex: [String: SeriesEntry] = [:]
    @Published var scheduledAirings: [ScheduledAiring] = []
    @Published var tuners: [Tuner] = []
    @Published var library: [LibraryEntry] = []
    @Published var archiveJobs: [ArchiveJob] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published var lastError: String?
    @Published var toast: String?
    @Published var playRequest: PlayRequest?
    @Published private(set) var guideLoadedAt: Date?

    private var toastTask: Task<Void, Never>?
    private var recordingsRefreshing = false
    /// Last time we asked the proxy to rescan the Tablo (POST /api/refresh).
    private var lastRescan: Date?

    init() {
        favoritesOnly = UserDefaults.standard.bool(forKey: "favoritesOnly")
    }

    // MARK: Loading

    func loadAll() async {
        loading = true
        defer { loading = false }
        do {
            async let ch = client.channels()
            async let rec = client.recordings()
            channels = try await ch
            recordings = try await rec
            lastError = nil
            loaded = true
        } catch {
            lastError = "Can't reach the proxy at \(client.baseURL): \(error.localizedDescription)"
            return
        }
        // Everything else is best-effort: a missing guide or library must not
        // take Live TV down with it.
        if let g = try? await client.guide() { guide = g; guideLoadedAt = Date() }
        if let f = try? await client.favorites() { favorites = Set(f) }
        if let s = try? await client.series() { seriesIndex = s }
        await refreshLibrary()
        await refreshTuners()
        await refreshScheduledAirings()
    }

    func refreshRecordings(rescan: Bool = true) async {
        if recordingsRefreshing { return }
        recordingsRefreshing = true
        defer { recordingsRefreshing = false }
        do {
            if rescan {
                try await client.refresh(guide: false)
                lastRescan = Date()
            }
            recordings = try await client.recordings()
            await refreshLibrary()
        } catch {
            showToast("Refresh failed: \(error.localizedDescription)")
        }
    }

    /// Opening the Recordings tab rescans the Tablo like the web UI does, but
    /// onAppear also fires on every pop back from a detail/show page and every
    /// tab switch; a rescan costs one device request per recording, so only
    /// rescan when the last one is stale and otherwise just re-read the
    /// proxy's cached list. Skipped until the initial load has finished.
    func refreshRecordingsOnAppear() async {
        guard loaded else { return }
        let stale = lastRescan.map { Date().timeIntervalSince($0) > 120 } ?? true
        await refreshRecordings(rescan: stale)
    }

    func refreshLibrary() async {
        if let l = try? await client.library() {
            library = l.entries
            archiveJobs = l.jobs
        }
    }

    private var recordingTunerChannels: [String] {
        tuners.filter { $0.inUse && $0.recording }.compactMap { $0.channel }.sorted()
    }

    func refreshTuners() async {
        guard let fresh = try? await client.tuners() else { return }
        let before = recordingTunerChannels
        tuners = fresh
        // A capture started or ended: pull the recordings list so REC badges
        // and the new entry show up without a manual refresh.
        if loaded && before != recordingTunerChannels {
            await refreshRecordings()
        }
    }

    func refreshScheduledAirings() async {
        if let s = try? await client.scheduledAirings() { scheduledAirings = s }
    }

    func refreshGuide(rescan: Bool) async {
        do {
            if rescan { try await client.refresh(guide: true) }
            guide = try await client.guide()
            guideLoadedAt = Date()
            if let s = try? await client.series() { seriesIndex = s }
            await refreshScheduledAirings()
        } catch {
            showToast("Guide refresh failed: \(error.localizedDescription)")
        }
    }

    /// After a schedule change the proxy invalidates its per-airing cache;
    /// re-read everything that renders schedule state.
    func refreshAfterScheduleChange() async {
        if let s = try? await client.series() { seriesIndex = s }
        await refreshScheduledAirings()
        await refreshTuners()
    }

    // Background loops, started by the root view for the app's lifetime.
    func tunerLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }
            await refreshTuners()
        }
    }

    func libraryLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            if archiveJobs.contains(where: { $0.isActive }) { await refreshLibrary() }
        }
    }

    func guideLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30 * 60))
            if Task.isCancelled { return }
            await refreshGuide(rescan: false)
        }
    }

    // MARK: Derived state

    var visibleChannels: [Channel] {
        if favoritesOnly && !favorites.isEmpty {
            return channels.filter { favorites.contains($0.id) }
        }
        return channels
    }

    func channel(id: Int) -> Channel? { channels.first { $0.id == id } }

    func airings(for channelId: Int) -> [GuideAiring] { guide[channelId] ?? [] }

    func currentAiring(for channelId: Int, at now: Date = Date()) -> GuideAiring? {
        airings(for: channelId).first { $0.isOn(at: now) }
    }

    func isChannelRecording(_ channelId: Int) -> Bool {
        let path = "/guide/channels/\(channelId)"
        return tuners.contains { $0.inUse && $0.recording && $0.channel == path }
    }

    /// The in-progress capture on a channel, if any (matched by channel number).
    func inProgressRecording(on ch: Channel) -> Recording? {
        recordings.first { $0.isInProgress && $0.channel.hasPrefix(ch.number + " ") }
    }

    /// Is this specific airing on the device's "will record" list?
    func isAiringScheduled(start: Date, channelIdentifier: String?) -> Bool {
        scheduledAirings.contains { a in
            guard let s = a.start, abs(s.timeIntervalSince(start)) < 1 else { return false }
            guard let want = channelIdentifier, !want.isEmpty, let have = a.channelIdentifier, !have.isEmpty else { return true }
            return want == have
        }
    }

    enum RecordMark { case notScheduled, scheduled, recordingNow, skipped }

    /// Red = will record (or is recording). Amber = the series is scheduled
    /// but Tablo is skipping THIS airing (duplicate or tuner conflict).
    func recordMark(for a: GuideAiring, on ch: Channel, now: Date = Date()) -> RecordMark {
        guard let showId = a.showId else { return .notScheduled }
        let seriesScheduled = seriesIndex[showId]?.isScheduled ?? false
        let airingScheduled = isAiringScheduled(start: a.start, channelIdentifier: ch.cloudId)
        if a.isOn(at: now) && isChannelRecording(ch.id) { return .recordingNow }
        if airingScheduled || (seriesScheduled && scheduledAirings.isEmpty) { return .scheduled }
        if seriesScheduled { return .skipped }
        return .notScheduled
    }

    func mergedRecordings() -> [RecItem] {
        var libById: [String: LibraryEntry] = [:]
        for l in library { libById[l.id] = l }
        var items = recordings.map { RecItem(id: $0.idString, rec: $0, lib: libById[$0.idString]) }
        let seen = Set(items.map { $0.id })
        for l in library where !seen.contains(l.id) {
            items.append(RecItem(id: l.id, rec: nil, lib: l))
        }
        return items
    }

    func mergedItem(_ id: String) -> RecItem? {
        mergedRecordings().first { $0.id == id }
    }

    func job(for id: String) -> ArchiveJob? {
        archiveJobs.first { $0.id == id }
    }

    nonisolated static func byDateDesc(_ a: RecItem, _ b: RecItem) -> Bool {
        (a.date ?? .distantPast) > (b.date ?? .distantPast)
    }

    func showGroups() -> [ShowGroup] {
        var groups: [String: (title: String, items: [RecItem])] = [:]
        for it in mergedRecordings() {
            let key = it.sortKey
            if groups[key] == nil { groups[key] = (it.title, []) }
            groups[key]?.items.append(it)
        }
        return groups.keys.sorted().map { key in
            let g = groups[key]!
            return ShowGroup(key: key, title: g.title, count: g.items.count,
                             savedCount: g.items.filter { $0.isSaved }.count,
                             anyLive: g.items.contains { $0.inProgress })
        }
    }

    // MARK: Favorites

    func toggleFavorite(_ ch: Channel) {
        if favorites.contains(ch.id) { favorites.remove(ch.id) } else { favorites.insert(ch.id) }
        let ids = channels.map { $0.id }.filter { favorites.contains($0) }
        Task { try? await client.saveFavorites(ids) }
    }

    // MARK: Record menu

    /// The record menu for a show/airing, mirroring the web UI: stop the
    /// capture that's running on this channel, else toggle this one airing,
    /// then the series rule.
    func recordActions(showId explicitShowId: String?, airing: GuideAiring?, channel: Channel?, capturing: Recording?) -> [RecordAction] {
        var out: [RecordAction] = []
        let showId = explicitShowId ?? airing?.showId

        if let cap = capturing {
            out.append(RecordAction(id: "stop", title: "Stop recording (keep partial)", destructive: true) { [weak self] in
                await self?.stopRecording(cap.idString)
            })
        } else if let a = airing, let showId {
            let chId = channel?.cloudId
            if isAiringScheduled(start: a.start, channelIdentifier: chId) {
                out.append(RecordAction(id: "unsingle", title: "Don't record this episode", destructive: true) { [weak self] in
                    await self?.recordAiring(showId: showId, airing: a, channelIdentifier: chId, schedule: false)
                })
            } else {
                out.append(RecordAction(id: "single", title: "Record this episode", destructive: false) { [weak self] in
                    await self?.recordAiring(showId: showId, airing: a, channelIdentifier: chId, schedule: true)
                })
            }
        }

        if let showId, let entry = seriesIndex[showId] {
            if entry.isScheduled {
                out.append(RecordAction(id: "cancel-series", title: "Cancel series recording", destructive: true) { [weak self] in
                    await self?.cancelSeries(showId: showId)
                })
            } else {
                out.append(RecordAction(id: "series-new", title: "Record new episodes", destructive: false) { [weak self] in
                    await self?.recordSeries(showId: showId, rule: "new")
                })
                out.append(RecordAction(id: "series-all", title: "Record all episodes", destructive: false) { [weak self] in
                    await self?.recordSeries(showId: showId, rule: "all")
                })
            }
        }
        return out
    }

    func recordAiring(showId: String, airing: GuideAiring, channelIdentifier: String?, schedule: Bool) async {
        do {
            try await client.recordAiring(showId: showId, datetime: airing.datetime, channelIdentifier: channelIdentifier, schedule: schedule)
            let airingNow = airing.start <= Date()
            if !schedule { showToast("Recording canceled") }
            else if airingNow { showToast("Recording scheduled — starting shortly") }
            else { showToast("Recording scheduled") }
            await refreshAfterScheduleChange()
            if schedule && airingNow { fastPollTuners() } else { delayedRefresh() }
        } catch {
            showToast("Record failed: \(error.localizedDescription)")
        }
    }

    func recordSeries(showId: String, rule: String) async {
        do {
            try await client.recordSeries(showId: showId, rule: rule)
            seriesIndex[showId]?.schedule = rule
            showToast(rule == "new" ? "Recording new episodes" : "Recording all episodes")
            await refreshAfterScheduleChange()
            fastPollTuners()
        } catch {
            showToast("Record failed: \(error.localizedDescription)")
        }
    }

    func cancelSeries(showId: String) async {
        do {
            try await client.cancelSeries(showId: showId)
            seriesIndex[showId]?.schedule = "none"
            showToast("Series recording canceled")
            await refreshAfterScheduleChange()
            delayedRefresh()
        } catch {
            showToast("Cancel failed: \(error.localizedDescription)")
        }
    }

    /// Tablo takes a few seconds to register a schedule change on its tuner;
    /// refresh again shortly so REC badges and the new entry appear.
    private func delayedRefresh() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            await refreshAfterScheduleChange()
            await refreshRecordings()
        }
    }

    /// After scheduling something that's on right now, poll the tuners
    /// quickly until capture actually starts (Tablo takes ~10-40s).
    private func fastPollTuners() {
        Task {
            let before = recordingTunerChannels
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(4))
                await refreshTuners()
                if recordingTunerChannels != before {
                    showToast("Recording started")
                    return
                }
            }
        }
    }

    // MARK: Recording management

    /// Returns whether the delete succeeded (callers only dismiss on success).
    @discardableResult
    func deleteRecording(_ id: String) async -> Bool {
        do {
            try await client.deleteRecording(id)
            recordings.removeAll { $0.idString == id }
            if !library.contains(where: { $0.id == id }) { clearResume(id) }
            showToast("Deleted from Tablo")
            delayedRefresh()
            return true
        } catch {
            showToast("Delete failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns whether the proxy accepted the stop. The player only treats the
    /// capture as ended on success — otherwise it's still recording.
    @discardableResult
    func stopRecording(_ id: String) async -> Bool {
        do {
            try await client.stopRecording(id)
            markRecordingEnded(id, state: "finished", recordedDuration: nil)
            showToast("Recording stopped")
            delayedRefresh()
            return true
        } catch {
            showToast("Stop failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Sync the cached entry so re-renders see the capture as over; the
    /// tuner list catches up a few seconds later.
    func markRecordingEnded(_ id: String, state: String, recordedDuration: Double?) {
        if let i = recordings.firstIndex(where: { $0.idString == id }) {
            recordings[i].state = state
            if let rd = recordedDuration, rd > 0 { recordings[i].recordedDuration = rd }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await refreshTuners()
        }
    }

    func archive(_ id: String) async {
        do {
            let job = try await client.archive(id)
            archiveJobs.removeAll { $0.id == id }
            if let job { archiveJobs.append(job) }
            showToast("Saving a copy on the server…")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func deleteLibraryEntry(_ id: String) async -> Bool {
        do {
            try await client.deleteLibraryEntry(id)
            library.removeAll { $0.id == id }
            archiveJobs.removeAll { $0.id == id }
            if !recordings.contains(where: { $0.idString == id }) { clearResume(id) }
            showToast("Saved copy deleted")
            return true
        } catch {
            showToast("Delete failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete the saved copy and the Tablo copy. Each half is attempted and
    /// reported; the resume position is only cleared once nothing is left.
    @discardableResult
    func deleteBoth(_ id: String) async -> Bool {
        var failures: [String] = []
        if library.contains(where: { $0.id == id }) {
            do {
                try await client.deleteLibraryEntry(id)
                library.removeAll { $0.id == id }
                archiveJobs.removeAll { $0.id == id }
            } catch {
                failures.append("saved copy: \(error.localizedDescription)")
            }
        }
        if recordings.contains(where: { $0.idString == id }) {
            do {
                try await client.deleteRecording(id)
                recordings.removeAll { $0.idString == id }
            } catch {
                failures.append("Tablo copy: \(error.localizedDescription)")
            }
        }
        delayedRefresh()
        guard failures.isEmpty else {
            showToast("Delete failed — " + failures.joined(separator: "; "))
            return false
        }
        clearResume(id)
        showToast("Deleted")
        return true
    }

    // MARK: Resume positions

    private func resumeKey(_ id: String) -> String { "resume.\(id)" }

    /// Saved position, or 0 when there is none worth resuming (near the start
    /// or within the last 30 seconds).
    func resumePosition(for id: String, duration: Double) -> Double {
        let p = UserDefaults.standard.double(forKey: resumeKey(id))
        guard p > 10 else { return 0 }
        if duration > 0 && p >= duration - 30 { return 0 }
        return p
    }

    func saveResume(_ id: String, position: Double) {
        guard position > 5 else { return }
        UserDefaults.standard.set(position.rounded(), forKey: resumeKey(id))
    }

    func clearResume(_ id: String) {
        UserDefaults.standard.removeObject(forKey: resumeKey(id))
    }

    func clearAllResumePositions() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("resume.") {
            d.removeObject(forKey: key)
        }
        showToast("Resume positions cleared")
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }
}
