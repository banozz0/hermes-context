import Foundation

extension ContextOccupancy {
    /// `45%`, `~45%` for an estimate, or nil before any measurement.
    public var percentText: String? {
        guard let percentage else { return nil }
        return (isEstimated ? "~" : "") + "\(Int(percentage.rounded()))%"
    }

    /// `90k / 200k` tokens of current prompt occupancy, `90k` alone when the window size is unknown,
    /// or nil before any measurement.
    public var tokensText: String? {
        guard let used else { return nil }
        return Self.compact(used) + (maximum.map { " / \(Self.compact($0))" } ?? "")
    }

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: String(format: tokens % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...: String(format: tokens % 1_000 == 0 ? "%.0fk" : "%.1fk", Double(tokens) / 1_000)
        default: "\(tokens)"
        }
    }
}

extension LiveSession {
    /// `now`, `4m`, `3h`, `2d` since the last activity.
    public func idleText(now: Date) -> String? {
        lastActivityAt.map { Self.span(since: $0, now: now) }
    }

    /// `just now`, `4m ago`, `3h ago`, `2d ago`.
    public static func elapsed(since date: Date, now: Date) -> String {
        let span = span(since: date, now: now)
        return span == "now" ? "just now" : "\(span) ago"
    }

    static func span(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
