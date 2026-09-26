import Foundation

// Parsing and display helpers shared by every screen.
enum Fmt {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses every timestamp shape the proxy emits: cloud guide airings
    /// ("2026-09-20T02:59:00Z"), device recordings ("2026-09-20T02:59Z", no
    /// seconds) and archive entries ("2026-09-20T02:59:00.123Z").
    static func date(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let t = s.firstIndex(of: "T") {
            let timeStart = s.index(after: t)
            let clock = s[timeStart...].prefix { $0.isNumber || $0 == ":" }
            if clock.count == 5 {   // HH:MM with no seconds
                s.insert(contentsOf: ":00", at: s.index(timeStart, offsetBy: 5))
            }
        }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }

    /// "45 min" / "1h 05m"
    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    /// "12:05" / "1:02:33"
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
    static func dayLabel(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    static func size(_ bytes: Double) -> String {
        if bytes >= 1e9 { return String(format: "%.1f GB", bytes / 1e9) }
        return "\(Int((bytes / 1e6).rounded())) MB"
    }

    /// Sort key that ignores leading articles so "The Rookie" files under R.
    static func titleKey(_ title: String) -> String {
        var s = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where s.hasPrefix(article) {
            s = String(s.dropFirst(article.count))
            break
        }
        return s
    }

    /// Section letter for the A–Z view.
    static func letter(_ title: String) -> String {
        guard let c = titleKey(title).first, c.isLetter else { return "#" }
        return String(c).uppercased()
    }
}
