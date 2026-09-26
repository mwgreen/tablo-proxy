import Foundation
import Combine

enum ProxyError: LocalizedError {
    case badURL
    case server(String)
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The proxy address is not a valid URL"
        case .server(let msg): return msg
        case .http(let code): return "Proxy returned HTTP \(code)"
        case .decoding(let what): return "Unexpected response from the proxy (\(what))"
        }
    }
}

// HTTP client for the tablo-proxy API. Same routes the web UI uses.
@MainActor
final class ProxyClient: ObservableObject {
    static let defaultBaseURL = "http://192.168.68.77:9480"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }

    private let session: URLSession

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? ProxyClient.defaultBaseURL
        let cfg = URLSessionConfiguration.default
        // Starting a stream waits for the first two transcoded segments and a
        // Tablo tuner lock, which can take a while.
        cfg.timeoutIntervalForRequest = 90
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    func url(_ path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return URL(string: base + path)
    }

    private static let pathSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: ProxyClient.pathSafe) ?? s
    }

    // MARK: Transport

    private func request(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        guard let u = url(path) else { throw ProxyError.badURL }
        var req = URLRequest(url: u)
        req.httpMethod = method
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        if code >= 400 {
            if let e = try? JSONDecoder().decode(APIError.self, from: data), let msg = e.error, !msg.isEmpty {
                throw ProxyError.server(msg)
            }
            throw ProxyError.http(code)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProxyError.decoding(String(describing: T.self))
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request("GET", path)
        return try decode(data)
    }

    private func post<T: Decodable>(_ path: String, json: Any? = nil) async throws -> T {
        let data = try await request("POST", path, json: json)
        return try decode(data)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request("DELETE", path)
        return try decode(data)
    }

    private func lossyArray<T: Decodable>(_ path: String) async throws -> [T] {
        let list: [Lossy<T>] = try await get(path)
        return list.compactMap { $0.value }
    }

    // MARK: Catalog

    func channels() async throws -> [Channel] { try await lossyArray("/api/channels") }
    func recordings() async throws -> [Recording] { try await lossyArray("/api/recordings") }
    func tuners() async throws -> [Tuner] { try await lossyArray("/api/tuners") }
    func scheduledAirings() async throws -> [ScheduledAiring] { try await lossyArray("/api/scheduled-airings") }
    func library() async throws -> LibraryResponse { try await get("/api/library") }

    /// Guide keyed by numeric channel id, airings sorted by start time.
    func guide() async throws -> [Int: [GuideAiring]] {
        let raw: [String: [Lossy<GuideAiring>]] = try await get("/api/guide")
        var out: [Int: [GuideAiring]] = [:]
        for (key, list) in raw {
            guard let id = Int(key) else { continue }
            out[id] = list.compactMap { $0.value }.sorted { $0.start < $1.start }
        }
        return out
    }

    func favorites() async throws -> [Int] {
        let raw: [LooseInt] = try await get("/api/favorites")
        return raw.compactMap { $0.value }
    }

    func saveFavorites(_ ids: [Int]) async throws {
        let _: Ignored = try await post("/api/favorites", json: ids)
    }

    func series() async throws -> [String: SeriesEntry] {
        let raw: [String: Lossy<SeriesEntry>] = try await get("/api/series")
        return raw.compactMapValues { $0.value }
    }

    /// Ask the proxy to rescan the Tablo (channels + recordings; guide too when asked).
    func refresh(guide: Bool) async throws {
        let _: Ignored = try await post(guide ? "/api/refresh?guide=1" : "/api/refresh")
    }

    // MARK: Recording schedule

    func recordSeries(showId: String, rule: String) async throws {
        let _: Ignored = try await post("/api/record/\(enc(showId))", json: ["rule": rule])
    }

    func cancelSeries(showId: String) async throws {
        let _: Ignored = try await delete("/api/record/\(enc(showId))")
    }

    func recordAiring(showId: String, datetime: String, channelIdentifier: String?, schedule: Bool) async throws {
        var body: [String: Any] = ["showId": showId, "datetime": datetime, "schedule": schedule]
        if let channelIdentifier, !channelIdentifier.isEmpty { body["channelIdentifier"] = channelIdentifier }
        let _: Ignored = try await post("/api/record-airing", json: body)
    }

    // MARK: Recording management

    func recordingStatus(_ id: Int) async throws -> RecordingStatus {
        try await get("/api/recording/\(id)/status")
    }

    func deleteRecording(_ id: String) async throws {
        let _: Ignored = try await delete("/api/recording/\(enc(id))")
    }

    func stopRecording(_ id: String) async throws {
        let _: Ignored = try await post("/api/recording/\(enc(id))/stop")
    }

    func archive(_ id: String) async throws -> ArchiveJob? {
        let r: ArchiveResponse = try await post("/api/archive/\(enc(id))")
        if let e = r.error, !e.isEmpty { throw ProxyError.server(e) }
        return r.job
    }

    func deleteLibraryEntry(_ id: String) async throws {
        let _: Ignored = try await delete("/api/library/\(enc(id))")
    }

    func libraryVideoURL(_ id: String) -> URL? { url("/library/video/\(enc(id))") }
    func libraryThumbURL(_ id: String) -> URL? { url("/library/thumb/\(enc(id))") }

    // MARK: Streaming sessions

    /// Starts a transcode session; returns the absolute playlist URL and session id.
    func startStream(path: String) async throws -> (url: URL, sessionId: String) {
        let s: StreamStart = try await get(path)
        if let e = s.error, !e.isEmpty { throw ProxyError.server(e) }
        guard let p = s.url, let sid = s.sessionId, let u = url(p) else {
            throw ProxyError.decoding("stream start")
        }
        return (u, sid)
    }

    /// Restarts the session's transcode at an absolute offset (seconds).
    func seek(session: String, offset: Double) async throws -> (url: URL, startOffset: Double) {
        let r: SeekResponse = try await post("/api/seek/\(enc(session))", json: ["offset": offset])
        if let e = r.error, !e.isEmpty { throw ProxyError.server(e) }
        guard let p = r.url, let u = url(p) else { throw ProxyError.decoding("seek") }
        return (u, r.startOffset)
    }

    func stopSession(_ id: String) async {
        _ = try? await request("POST", "/api/stop/\(enc(id))")
    }

    /// The proxy reaps idle sessions; a HEAD on the playlist keeps ours alive
    /// and doubles as a dead-session probe. nil when the proxy can't be reached.
    func playlistAlive(_ playlist: URL) async -> Bool? {
        var req = URLRequest(url: playlist)
        req.httpMethod = "HEAD"
        guard let result = try? await session.data(for: req) else { return nil }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
        return code != 404
    }
}
