import Foundation

// Thin client for the tablo-proxy HTTP API. Same routes the web UI uses.
struct Channel: Codable, Identifiable, Hashable {
    let id: Int
    let number: String
    let name: String
}

struct Recording: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let episode: String?
    let episodeNumber: Int?
    let seasonNumber: Int?
    let date: String?
    let duration: Double?
    let channel: String?
    let state: String?
}

struct StreamStart: Codable {
    let url: String
    let sessionId: String
    let error: String?
}

@MainActor
final class ProxyClient: ObservableObject {
    static let shared = ProxyClient()

    // The proxy on sanctarus (wired address). Editable in Settings.
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var channels: [Channel] = []
    @Published var recordings: [Recording] = []
    @Published var lastError: String?

    private init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "http://192.168.68.77:9480"
    }

    private func url(_ path: String) -> URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let u = url(path) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: u)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func refresh() async {
        do {
            async let ch = get("/api/channels", as: [Channel].self)
            async let rec = get("/api/recordings", as: [Recording].self)
            channels = try await ch
            recordings = try await rec
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Starts a transcode session; returns the absolute playlist URL and session id.
    func startStream(path: String) async throws -> (URL, String) {
        let start = try await get(path, as: StreamStart.self)
        if let e = start.error { throw NSError(domain: "proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        guard let u = url(start.url) else { throw URLError(.badURL) }
        return (u, start.sessionId)
    }

    func stopSession(_ id: String) async {
        guard let u = url("/api/stop/\(id)") else { return }
        var req = URLRequest(url: u); req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    // The proxy reaps idle sessions; a HEAD on the playlist keeps ours alive.
    func keepAlive(playlist: URL) async {
        var req = URLRequest(url: playlist); req.httpMethod = "HEAD"
        _ = try? await URLSession.shared.data(for: req)
    }
}
