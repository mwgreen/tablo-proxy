import Foundation

// MARK: - Lenient decoding
// The proxy's JSON comes from three upstreams (Tablo device, Tablo cloud, the
// local archive index) and a field that is a number in one place can be a
// string in another. Decode by intent, not by exact JSON type, so one odd
// value never blanks a whole screen.
extension KeyedDecodingContainer {
    func int(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key), v.isFinite { return Int(v) }
        if let v = try? decodeIfPresent(String.self, forKey: key) {
            if let i = Int(v) { return i }
            if let d = Double(v), d.isFinite { return Int(d) }
        }
        return nil
    }

    func double(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return Double(v) }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return Double(v) }
        return nil
    }

    func string(_ key: Key) -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return String(v) }
        return nil
    }

    /// JavaScript-style truthiness: true, non-zero, non-empty string, or any
    /// object/array. The tuner API's `recording` field is one of these.
    func truthy(_ key: Key) -> Bool {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return !v.isEmpty && v != "false" && v != "0" }
        guard contains(key) else { return false }
        return (try? decodeNil(forKey: key)) == false
    }
}

/// Wraps an element so one undecodable entry in an array is dropped instead of
/// failing the whole array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// An id that may arrive as a number or a string.
struct LooseInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else if let d = try? c.decode(Double.self), d.isFinite { value = Int(d) }
        else { value = nil }
    }
}

/// Decodes and ignores any JSON body (for endpoints that only report `{ok:true}`).
struct Ignored: Decodable {
    init(from decoder: Decoder) throws {}
}

struct APIError: Decodable {
    let error: String?
    /// /api/seek: a newer seek for the same session reached the proxy first.
    let superseded: Bool?
}

// MARK: - Channels

struct Channel: Decodable, Identifiable, Hashable {
    let id: Int
    let number: String       // "7.1"
    let name: String         // network or call sign
    let callSign: String
    let cloudId: String?     // channel_identifier, used for per-airing scheduling

    enum CodingKeys: String, CodingKey { case id, number, name, callSign, cloudId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.int(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "channel without id"))
        }
        self.id = id
        number = c.string(.number) ?? "?"
        name = c.string(.name) ?? "Unknown"
        callSign = c.string(.callSign) ?? ""
        cloudId = c.string(.cloudId)
    }

    var label: String { "\(number) \(name)" }
    /// The tuner API names channels by device path.
    var tunerPath: String { "/guide/channels/\(id)" }
}

// MARK: - Recordings on the Tablo

struct Recording: Decodable, Identifiable, Hashable {
    let id: Int
    let path: String?
    let title: String
    let episode: String
    let episodeNumber: Int?
    let seasonNumber: Int?
    let synopsis: String
    let date: String
    let duration: Double            // scheduled length, seconds
    var recordedDuration: Double    // what the device actually captured
    var state: String               // "recording" | "finished" | "failed" | ""
    let channel: String             // "7.1 KMGH"
    let imageId: Int?

    enum CodingKeys: String, CodingKey {
        case id, path, title, episode, episodeNumber, seasonNumber, synopsis = "description"
        case date, duration, recordedDuration, state, channel, imageId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.int(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "recording without id"))
        }
        self.id = id
        path = c.string(.path)
        title = c.string(.title) ?? "Unknown"
        episode = c.string(.episode) ?? ""
        episodeNumber = c.int(.episodeNumber)
        seasonNumber = c.int(.seasonNumber)
        synopsis = c.string(.synopsis) ?? ""
        date = c.string(.date) ?? ""
        duration = c.double(.duration) ?? 0
        recordedDuration = c.double(.recordedDuration) ?? 0
        state = c.string(.state) ?? ""
        channel = c.string(.channel) ?? ""
        imageId = c.int(.imageId)
    }

    var idString: String { String(id) }
    var startDate: Date? { Fmt.date(date) }

    /// The device's capture state is authoritative: a stopped partial is
    /// "finished" even though the wall clock says the airing is still on.
    var isInProgress: Bool {
        if !state.isEmpty { return state == "recording" }
        guard let start = startDate, duration > 0 else { return false }
        let now = Date()
        return now >= start && now < start.addingTimeInterval(duration)
    }

    /// Actual watchable length: the recorded duration for completed captures
    /// (partials are shorter than scheduled), scheduled duration otherwise.
    var effectiveDuration: Double {
        let finished = !state.isEmpty && state != "recording"
        return (finished && recordedDuration > 0) ? recordedDuration : duration
    }

    var isPartial: Bool {
        !state.isEmpty && state != "recording" && recordedDuration > 0 && duration > 0 && recordedDuration < duration * 0.85
    }

    var episodeLine: String {
        if let s = seasonNumber, let e = episodeNumber {
            return "S\(s)E\(e)" + (episode.isEmpty ? "" : ": \(episode)")
        }
        return episode
    }
}

// MARK: - Local archive

struct LibraryEntry: Decodable, Identifiable, Hashable {
    let id: String              // Tablo recording id, kept after the Tablo copy is deleted
    let title: String
    let episode: String
    let episodeNumber: Int?
    let seasonNumber: Int?
    let synopsis: String
    let date: String
    let duration: Double
    let channel: String
    let size: Double
    let thumb: String?
    let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, episode, episodeNumber, seasonNumber, synopsis = "description"
        case date, duration, channel, size, thumb, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.string(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "library entry without id"))
        }
        self.id = id
        title = c.string(.title) ?? "Unknown"
        episode = c.string(.episode) ?? ""
        episodeNumber = c.int(.episodeNumber)
        seasonNumber = c.int(.seasonNumber)
        synopsis = c.string(.synopsis) ?? ""
        date = c.string(.date) ?? ""
        duration = c.double(.duration) ?? 0
        channel = c.string(.channel) ?? ""
        size = c.double(.size) ?? 0
        thumb = c.string(.thumb)
        archivedAt = c.string(.archivedAt)
    }

    var startDate: Date? { Fmt.date(date) }
    var episodeLine: String {
        if let s = seasonNumber, let e = episodeNumber {
            return "S\(s)E\(e)" + (episode.isEmpty ? "" : ": \(episode)")
        }
        return episode
    }
}

struct ArchiveJob: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let episode: String
    let status: String          // queued | transcoding | verifying | done | failed
    let progress: Double        // 0…1
    let error: String?

    enum CodingKeys: String, CodingKey { case id, title, episode, status, progress, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.string(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "job without id"))
        }
        self.id = id
        title = c.string(.title) ?? ""
        episode = c.string(.episode) ?? ""
        status = c.string(.status) ?? ""
        progress = c.double(.progress) ?? 0
        error = c.string(.error)
    }

    var isActive: Bool { status == "queued" || status == "transcoding" || status == "verifying" }

    var label: String {
        switch status {
        case "queued": return "QUEUED"
        case "verifying": return "VERIFYING"
        case "transcoding": return "SAVING \(Int((progress * 100).rounded()))%"
        case "failed": return "SAVE FAILED"
        case "done": return "SAVED"
        default: return status.uppercased()
        }
    }
}

struct LibraryResponse: Decodable {
    let entries: [LibraryEntry]
    let jobs: [ArchiveJob]

    enum CodingKeys: String, CodingKey { case entries, jobs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = ((try? c.decodeIfPresent([Lossy<LibraryEntry>].self, forKey: .entries)) ?? []).compactMap { $0.value }
        jobs = ((try? c.decodeIfPresent([Lossy<ArchiveJob>].self, forKey: .jobs)) ?? []).compactMap { $0.value }
    }
}

// MARK: - Tuners

struct Tuner: Decodable, Hashable {
    let inUse: Bool
    let recording: Bool
    let channel: String?        // "/guide/channels/123"

    enum CodingKeys: String, CodingKey { case inUse = "in_use", recording, channel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inUse = c.truthy(.inUse)
        recording = c.truthy(.recording)
        channel = c.string(.channel)
    }
}

// MARK: - Guide

struct GuideAiring: Decodable, Identifiable, Hashable {
    let datetime: String        // as the proxy sent it; echoed back when scheduling
    let start: Date
    let duration: Double        // seconds (1800 when the guide omits it)
    let showId: String?         // cloud show identifier, key into the series index
    let showTitle: String
    let episodeTitle: String
    let season: Int?
    let episodeNumber: Int?
    let synopsis: String

    var end: Date { start.addingTimeInterval(duration) }
    var id: String { "\(datetime)#\(showId ?? showTitle)" }

    enum CodingKeys: String, CodingKey { case datetime, start, duration, show, title, episode, synopsis = "description" }
    enum ShowKeys: String, CodingKey { case identifier, title }
    enum EpisodeKeys: String, CodingKey { case season, episodeNumber }
    enum SeasonKeys: String, CodingKey { case number }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        datetime = c.string(.datetime) ?? c.string(.start) ?? ""
        guard let s = Fmt.date(datetime) else {
            throw DecodingError.dataCorruptedError(forKey: .datetime, in: c, debugDescription: "unparseable airing time")
        }
        start = s
        let d = c.double(.duration) ?? 0
        duration = d > 0 ? d : 1800

        var sid: String? = nil
        var stitle = ""
        if let sc = try? c.nestedContainer(keyedBy: ShowKeys.self, forKey: .show) {
            sid = sc.string(.identifier)
            stitle = sc.string(.title) ?? ""
        }
        showId = sid
        episodeTitle = c.string(.title) ?? ""
        showTitle = stitle.isEmpty ? episodeTitle : stitle

        var sn: Int? = nil
        var en: Int? = nil
        if let ec = try? c.nestedContainer(keyedBy: EpisodeKeys.self, forKey: .episode) {
            en = ec.int(.episodeNumber)
            if let sc = try? ec.nestedContainer(keyedBy: SeasonKeys.self, forKey: .season) {
                sn = sc.int(.number)
            }
        }
        season = sn
        episodeNumber = en
        synopsis = c.string(.synopsis) ?? ""
    }

    /// Series title first (matches the guide grid); episode title appended when distinct.
    var displayTitle: String {
        if !showTitle.isEmpty, !episodeTitle.isEmpty, showTitle != episodeTitle {
            return "\(showTitle) · \(episodeTitle)"
        }
        return showTitle.isEmpty ? episodeTitle : showTitle
    }

    /// "S8E2", or "E306" when there's no season. Empty when the guide has no
    /// episode number (news, talk, paid programming) — the guide sends season 0
    /// and no number for those, which would otherwise render as "S0E?".
    var episodeInfo: String {
        guard let e = episodeNumber, e > 0 else { return "" }
        if let s = season, s > 0 { return "S\(s)E\(e)" }
        return "E\(e)"
    }

    func isOn(at now: Date) -> Bool { now >= start && now < end }
}

struct SeriesEntry: Decodable, Hashable {
    let path: String
    let title: String
    var schedule: String        // "none" | "new" | "all"

    enum CodingKeys: String, CodingKey { case path, title, schedule }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.string(.path) ?? ""
        title = c.string(.title) ?? ""
        schedule = c.string(.schedule) ?? "none"
    }

    var isScheduled: Bool { !schedule.isEmpty && schedule != "none" }
}

/// An airing the device's scheduler will actually capture. A series rule alone
/// isn't enough: Tablo skips duplicates and conflicts.
struct ScheduledAiring: Decodable, Hashable {
    let datetime: String
    let start: Date?
    let duration: Double
    let channelIdentifier: String?
    let title: String
    let state: String

    enum CodingKeys: String, CodingKey { case datetime, duration, channelIdentifier, title, state }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        datetime = c.string(.datetime) ?? ""
        start = Fmt.date(datetime)
        duration = c.double(.duration) ?? 0
        channelIdentifier = c.string(.channelIdentifier)
        title = c.string(.title) ?? ""
        state = c.string(.state) ?? "scheduled"
    }
}

// MARK: - Streaming

struct StreamStart: Decodable {
    let url: String?
    let sessionId: String?
    let error: String?

    enum CodingKeys: String, CodingKey { case url, sessionId, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url)
        sessionId = c.string(.sessionId)
        error = c.string(.error)
    }
}

struct SeekResponse: Decodable {
    let url: String?
    let startOffset: Double
    let error: String?

    enum CodingKeys: String, CodingKey { case url, startOffset, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.string(.url)
        startOffset = c.double(.startOffset) ?? 0
        error = c.string(.error)
    }
}

struct RecordingStatus: Decodable {
    let state: String
    let recordedDuration: Double
    let scheduledDuration: Double

    enum CodingKeys: String, CodingKey { case state, recordedDuration, scheduledDuration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.string(.state) ?? ""
        recordedDuration = c.double(.recordedDuration) ?? 0
        scheduledDuration = c.double(.scheduledDuration) ?? 0
    }
}

struct ArchiveResponse: Decodable {
    let job: ArchiveJob?
    let error: String?

    enum CodingKeys: String, CodingKey { case job, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = try? c.decodeIfPresent(ArchiveJob.self, forKey: .job)
        error = c.string(.error)
    }
}
