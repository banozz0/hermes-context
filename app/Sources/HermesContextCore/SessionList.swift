import Foundation

/// The merged live list: every profile's lanes, one row per routing ID, sorted and searched.
public struct SessionList: Equatable, Sendable {
    /// Idle lanes this old are hidden until they move again, unless the caller passes its own age.
    public static let defaultHideAfter: TimeInterval = 24 * 60 * 60

    /// The lanes the popover shows, searched and sorted.
    public let current: [LiveSession]
    /// Idle lanes past the hide age. Hermes never closes a Discord session, so this is how one closes:
    /// never drawn, searched, counted or warned about. Kept so Insights can still name them.
    public let hidden: [LiveSession]
    /// Routing IDs whose gateway heartbeat is stale: their rows are the last snapshot, shown Offline.
    public let offline: Set<String>

    public var isEmpty: Bool { current.isEmpty }
    /// Every lane, visible then hidden; with a query, the visible part is only the matches.
    public var all: [LiveSession] { current + hidden }

    public init(snapshots: [ProfileSnapshot], query: String = "", now: Date, hideAfter: TimeInterval = defaultHideAfter) {
        var lanes: [String: LiveSession] = [:]
        var offline: Set<String> = []
        for snapshot in snapshots {
            let isOffline = snapshot.isOffline(at: now)
            for session in snapshot.sessions {
                // Routing IDs already carry the profile, so a collision is the same lane seen twice; keep the newest.
                if let existing = lanes[session.id], Self.recency(existing) >= Self.recency(session) { continue }
                lanes[session.id] = session
                if isOffline { offline.insert(session.id) } else { offline.remove(session.id) }
            }
        }
        let terms = Self.terms(query)
        var current: [LiveSession] = [], hidden: [LiveSession] = []
        for session in lanes.values.sorted(by: Self.precedes) {
            if Self.isHidden(session, now: now, after: hideAfter) {
                hidden.append(session)
            } else if terms.allSatisfy({ term in Self.searchFields(session).contains { $0.contains(term) } }) {
                current.append(session)
            }
        }
        (self.current, self.hidden) = (current, hidden)
        self.offline = offline.intersection((current + hidden).map(\.id))
    }

    public func isOffline(_ session: LiveSession) -> Bool { offline.contains(session.id) }

    /// Needs attention before Working before Idle, then most recent activity first.
    public static func precedes(_ lhs: LiveSession, _ rhs: LiveSession) -> Bool {
        if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
        if recency(lhs) != recency(rhs) { return recency(lhs) > recency(rhs) }
        if lhs.profile != rhs.profile { return lhs.profile < rhs.profile }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id < rhs.id
    }

    /// Only Idle lanes hide; stalled Working or Needs attention lanes stay in view however old.
    public static func isHidden(_ session: LiveSession, now: Date, after age: TimeInterval) -> Bool {
        guard session.state == .idle else { return false }
        guard let last = session.lastActivityAt else { return true }
        return now.timeIntervalSince(last) >= age
    }

    /// Search covers session name, profile, model and Discord channel label; never IDs.
    static func searchFields(_ session: LiveSession) -> [String] {
        [session.displayName, session.profile, session.model ?? "", session.route.channelLabel ?? ""].map(normalize)
    }

    static func terms(_ query: String) -> [String] {
        normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func recency(_ session: LiveSession) -> Date {
        session.lastActivityAt ?? .distantPast
    }
}
