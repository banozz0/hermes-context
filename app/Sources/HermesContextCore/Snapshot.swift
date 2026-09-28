import Foundation

/// One profile's `hermes-context/v1/snapshot.json`, decoded against the v1 bridge contract.
/// Fields outside the contract are never mapped, so they cannot reach the app.
public struct ProfileSnapshot: Equatable, Sendable {
    public static let contractVersion = "hermes-context.v1"

    public let profile: String
    public let generatedAt: Date
    public let heartbeatAt: Date
    public let offlineAfterSeconds: Int
    /// What the writer declared; the reader's own clock decides staleness in `isOffline(at:)`.
    public let freshness: String
    public let sessions: [LiveSession]
    /// What a Hermes update switched off in this profile's plugin; empty when nothing is lost.
    public let degraded: [DegradedFeature]

    /// Offline once the heartbeat is older than the producer's timeout, judged on this Mac's clock.
    /// An empty session list is never offline by itself.
    public func isOffline(at now: Date) -> Bool {
        freshness == "offline" || now.timeIntervalSince(heartbeatAt) > TimeInterval(offlineAfterSeconds)
    }
}

/// The closed v1 set of plugin features a Hermes update can switch off, as the snapshot's `degraded` names them.
public enum DegradedFeature: String, Decodable, Sendable, CaseIterable {
    case attention
    case backfill
    case contextWindow = "context_window"
    case lineage
    case sessions
    case startup
    case subagents
    case titles
    case toolHistory = "tool_history"

    /// What the user loses, as the diagnostic line names it. `sessions` has its own sentence instead.
    public var userWords: String {
        switch self {
        case .attention: "needs-attention status"
        case .backfill: "sessions listed at startup"
        case .contextWindow: "context window sizes"
        case .lineage: "session history links"
        case .sessions: "sessions"
        case .startup: "status at gateway start"
        case .subagents: "subagent filtering"
        case .titles: "session titles"
        case .toolHistory: "tool history"
        }
    }
}

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case working
    case needsAttention = "needs_attention"
    case idle

    /// Needs attention outranks Working, which outranks Idle.
    public var rank: Int {
        switch self {
        case .needsAttention: 0
        case .working: 1
        case .idle: 2
        }
    }

    public var label: String {
        switch self {
        case .working: "Working"
        case .needsAttention: "Needs attention"
        case .idle: "Idle"
        }
    }
}

public struct DiscordRoute: Equatable, Sendable {
    public let guildID: String?
    public let channelID: String?
    public let threadID: String?
    /// `#ops`: the channel the lane lives in (a thread's parent), when the gateway directory knows it.
    public let channelLabel: String?

    public init(guildID: String?, channelID: String?, threadID: String?, channelLabel: String? = nil) {
        self.guildID = guildID
        self.channelID = channelID
        self.threadID = threadID
        self.channelLabel = channelLabel
    }
}

public struct ContextOccupancy: Equatable, Sendable {
    public let used: Int?
    public let maximum: Int?
    public let percentage: Double?
    public let source: String?
    public let measuredAt: Date?

    /// Only provider-reported prompt usage is exact; any other source is disclosed as an estimate.
    public var isEstimated: Bool { source != nil && source != "provider_reported" }
}

/// One current routing lane: profile + platform + Discord location. Its `id` survives `/new`.
public struct LiveSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let profile: String
    public let platform: String
    public let sessionID: String
    public let lineageRootID: String
    public let previousSessionID: String?
    public let route: DiscordRoute
    public let displayName: String
    public let state: SessionState
    public let model: String?
    public let provider: String?
    public let context: ContextOccupancy
    public let currentTool: String?
    public let turnStartedAt: Date?
    public let lastActivityAt: Date?

    /// Profile identity as a label: `harry` → `Harry`.
    public var profileLabel: String { Self.profileLabel(profile) }

    /// `harry` → `Harry`.
    public static func profileLabel(_ profile: String) -> String { profile.prefix(1).uppercased() + profile.dropFirst() }
}

public enum SnapshotError: Error, Equatable, CustomStringConvertible {
    case unsupportedContract(String)
    case malformed(String)
    case invalidTimestamp(String)
    case profileMismatch(snapshot: String, session: String)

    public var description: String {
        switch self {
        case .unsupportedContract(let version): "Unsupported bridge contract \(version)"
        case .malformed(let detail): "Malformed snapshot: \(detail)"
        case .invalidTimestamp(let value): "Invalid timestamp \(value)"
        case .profileMismatch(let snapshot, let session): "Session for \(session) inside \(snapshot) snapshot"
        }
    }
}

public enum SnapshotDecoder {
    public static func decode(_ data: Data) throws -> ProfileSnapshot {
        let wire: Wire.Snapshot
        do {
            wire = try JSONDecoder().decode(Wire.Snapshot.self, from: data)
        } catch let error as DecodingError {
            // A newer contract may change shape, so name the version before the shape error.
            if let version = try? JSONDecoder().decode(Wire.Version.self, from: data).contract_version,
               version != ProfileSnapshot.contractVersion {
                throw SnapshotError.unsupportedContract(version)
            }
            throw SnapshotError.malformed(describe(error))
        }
        guard wire.contract_version == ProfileSnapshot.contractVersion else {
            throw SnapshotError.unsupportedContract(wire.contract_version)
        }
        guard wire.gateway.offline_after_seconds >= 1 else {
            throw SnapshotError.malformed("gateway.offline_after_seconds must be positive")
        }
        guard ["live", "offline"].contains(wire.freshness) else {
            throw SnapshotError.malformed("freshness \(wire.freshness)")
        }
        guard Set(wire.sessions.map(\.routing_id)).count == wire.sessions.count else {
            throw SnapshotError.malformed("duplicate routing_id")
        }
        let degraded = wire.degraded ?? []
        guard Set(degraded).count == degraded.count else {
            throw SnapshotError.malformed("duplicate degraded feature")
        }
        let sessions = try wire.sessions.map { row in
            guard row.profile == wire.profile else {
                throw SnapshotError.profileMismatch(snapshot: wire.profile, session: row.profile)
            }
            guard isIdentity(row.routing_id) else {
                throw SnapshotError.malformed("routing_id \(row.routing_id)")
            }
            if let percentage = row.context.percentage, !(0...100).contains(percentage) {
                throw SnapshotError.malformed("context.percentage \(percentage)")
            }
            if (row.context.used ?? 0) < 0 || (row.context.maximum ?? 0) < 0 {
                throw SnapshotError.malformed("negative context tokens")
            }
            return LiveSession(
                id: row.routing_id,
                profile: row.profile,
                platform: row.platform,
                sessionID: row.session_id,
                lineageRootID: row.lineage_root_id,
                previousSessionID: row.previous_session_id,
                route: DiscordRoute(
                    guildID: row.discord_route.guild_id,
                    channelID: row.discord_route.channel_id,
                    threadID: row.discord_route.thread_id,
                    channelLabel: row.discord_route.channel_label
                ),
                displayName: row.display_name,
                state: row.state,
                model: row.model,
                provider: row.provider,
                context: ContextOccupancy(
                    used: row.context.used,
                    maximum: row.context.maximum,
                    percentage: row.context.percentage,
                    source: row.context.source,
                    measuredAt: try row.context.measured_at.map(parseTimestamp)
                ),
                currentTool: row.current_tool,
                turnStartedAt: try row.timing.turn_started_at.map(parseTimestamp),
                lastActivityAt: try row.timing.last_activity_at.map(parseTimestamp)
            )
        }
        return ProfileSnapshot(
            profile: wire.profile,
            generatedAt: try parseTimestamp(wire.generated_at),
            heartbeatAt: try parseTimestamp(wire.gateway.heartbeat_at),
            offlineAfterSeconds: wire.gateway.offline_after_seconds,
            freshness: wire.freshness,
            sessions: sessions,
            degraded: degraded
        )
    }

    /// `sessions[0].state: Cannot initialize SessionState from invalid String value bogus`: path, then reason.
    static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .dataCorrupted(let found): context = found
        case .keyNotFound(let key, let found):
            return "\(path(found.codingPath + [key])): missing"
        @unknown default: return String(describing: error)
        }
        let at = path(context.codingPath)
        return at.isEmpty ? context.debugDescription : "\(at): \(context.debugDescription)"
    }

    static func path(_ keys: [CodingKey]) -> String {
        keys.reduce("") { path, key in
            if let index = key.intValue { return "\(path)[\(index)]" }
            return path.isEmpty ? key.stringValue : "\(path).\(key.stringValue)"
        }
    }

    /// `hc1:` plus 64 lowercase hex digits: the v1 routing and event identity.
    static func isIdentity(_ value: String) -> Bool {
        let hex = value.utf8.dropFirst(4)
        return value.hasPrefix("hc1:") && hex.count == 64 && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The observer writes UTC with milliseconds (`2026-09-24T10:04:00.000Z`); accept whole seconds too.
    public static func parseTimestamp(_ value: String) throws -> Date {
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        throw SnapshotError.invalidTimestamp(value)
    }
}

/// The v1 wire shape, field for field. Snake case matches the contract schema.
private enum Wire {
    struct Version: Decodable { let contract_version: String }

    struct Snapshot: Decodable {
        let contract_version: String
        let profile: String
        let generated_at: String
        let freshness: String
        let gateway: Gateway
        let sessions: [Session]
        let degraded: [DegradedFeature]?
    }

    struct Gateway: Decodable {
        let heartbeat_at: String
        let offline_after_seconds: Int
    }

    struct Session: Decodable {
        let routing_id: String
        let profile: String
        let platform: String
        let session_id: String
        let lineage_root_id: String
        let previous_session_id: String?
        let discord_route: Route
        let display_name: String
        let state: SessionState
        let model: String?
        let provider: String?
        let context: Context
        let current_tool: String?
        let timing: Timing
    }

    struct Route: Decodable {
        let guild_id: String?
        let channel_id: String?
        let thread_id: String?
        let channel_label: String?
    }

    struct Context: Decodable {
        let used: Int?
        let maximum: Int?
        let percentage: Double?
        let source: String?
        let measured_at: String?
    }

    struct Timing: Decodable {
        let turn_started_at: String?
        let last_activity_at: String?
    }
}
