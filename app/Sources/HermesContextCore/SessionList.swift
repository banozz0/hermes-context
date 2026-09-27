import Foundation

/// The merged live list: every profile's lanes, one row per routing ID, sorted and searched.
public struct SessionList: Equatable, Sendable {
    /// Idle lanes this old move under the collapsed Older section.
    public static let olderAfter: TimeInterval = 24 * 60 * 60

    public let current: [LiveSession]
    public let older: [LiveSession]
    /// Routing IDs whose gateway heartbeat is stale: their rows are the last snapshot, shown Offline.
    public let offline: Set<String>

    public var isEmpty: Bool { current.isEmpty && older.isEmpty }
    /// Every lane, current then Older.
    public var all: [LiveSession] { current + older }

    public init(snapshots: [ProfileSnapshot], query: String = "", now: Date) {
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
        let matching = lanes.values
            .filter { session in terms.allSatisfy { term in Self.searchFields(session).contains { $0.contains(term) } } }
            .sorted(by: Self.precedes)
        self.offline = offline.intersection(matching.map(\.id))
        current = matching.filter { !Self.isOlder($0, now: now) }
        older = matching.filter { Self.isOlder($0, now: now) }
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

    /// Only Idle lanes age out; stalled Working or Needs attention lanes stay in view.
    public static func isOlder(_ session: LiveSession, now: Date) -> Bool {
        guard session.state == .idle else { return false }
        guard let last = session.lastActivityAt else { return true }
        return now.timeIntervalSince(last) >= olderAfter
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
