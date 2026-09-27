import Foundation

/// One completed model request (`kind: model_request`) from `hermes-context/v1/events/`, decoded against the v1
/// event contract. This is the whole durable observation: no current tool, message, prompt or response exists here.
public struct TelemetryEvent: Equatable, Sendable {
    public let eventID: String
    /// Per-profile and monotonic: the importer's cursor and gap evidence.
    public let sequence: Int
    public let routingID: String
    public let lineageRootID: String
    public let previousSessionID: String?
    public let sessionID: String
    public let timestamp: Date
    public let profile: String
    public let model: String?
    public let provider: String?
    public let state: SessionState
    public let context: ContextOccupancy
}

/// One completed top-level tool call: which tool (and which skill, for `skill_view`), how large its result was by
/// Hermes's rough estimate, how long it ran and whether it failed. Never its arguments, result or error text.
public struct ToolCallEvent: Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case ok, error }

    public let eventID: String
    /// Shared with the profile's model requests, so one gap check covers both.
    public let sequence: Int
    public let routingID: String
    public let lineageRootID: String
    public let previousSessionID: String?
    public let sessionID: String
    /// The `eventID` of the model request that issued this call; `nil` when Hermes named none.
    public let requestEventID: String?
    public let timestamp: Date
    public let profile: String
    public let toolName: String
    /// The skill a `skill_view` call loaded; `nil` for every other tool.
    public let skillName: String?
    /// Hermes's rough token estimate of the result the call added to context, never a provider count.
    public let estimatedTokens: Int
    public let durationMS: Int
    public let status: Status
}

/// One event file's record: the two kinds share a profile's sequence and the importer's cursor.
public enum TelemetryRecord: Equatable, Sendable {
    case request(TelemetryEvent)
    case toolCall(ToolCallEvent)

    /// What the importer checks against the record's file name and Hermes home.
    var identity: (eventID: String, sequence: Int, profile: String) {
        switch self {
        case .request(let event): (event.eventID, event.sequence, event.profile)
        case .toolCall(let call): (call.eventID, call.sequence, call.profile)
        }
    }
}

/// Why an event file was refused. Reasons name fields, never values, so a rejected record's contents cannot
/// reach the issue log.
public enum EventError: Error, Equatable, CustomStringConvertible {
    case unsupportedContract
    case malformed(String)

    public var description: String {
        switch self {
        case .unsupportedContract: "unsupported contract version"
        case .malformed(let reason): reason
        }
    }
}

public enum EventDecoder {
    static let identityFields: Set<String> = [
        "contract_version", "kind", "event_id", "sequence", "routing_id", "lineage_root_id", "previous_session_id",
        "session_id", "timestamp", "profile",
    ]
    static let contextFields: Set<String> = ["used", "maximum", "percentage", "source", "measured_at"]
    /// `kind` picks the record's fields beyond the shared ones, and its decoder.
    private static let kinds: [String: (fields: Set<String>, decode: @Sendable ([String: Any], Data) throws -> TelemetryRecord)] = [
        "model_request": (identityFields.union(["model", "provider", "state", "context"]), { object, data in
            try exactFields(object["context"] as? [String: Any] ?? [:], contextFields, at: "context.")
            return .request(try request(decodeRecord(data)))
        }),
        "tool_call": (identityFields.union(["request_event_id", "tool_name", "skill_name", "estimated_tokens", "duration_ms", "status"]),
                      { _, data in .toolCall(try toolCall(decodeRecord(data))) }),
    ]

    /// Strict: an unknown field anywhere rejects the whole record, so no unapproved data is ever mapped.
    public static func decode(_ data: Data) throws -> TelemetryRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventError.malformed("not a JSON object")
        }
        // A newer contract may change shape, so name the version before the shape.
        guard object["contract_version"] as? String == ProfileSnapshot.contractVersion else {
            throw object["contract_version"] is String ? EventError.unsupportedContract : EventError.malformed("contract_version: missing")
        }
        guard let kind = (object["kind"] as? String).flatMap({ kinds[$0] }) else {
            throw EventError.malformed(object["kind"] == nil ? "kind: missing" : "kind: invalid value")
        }
        try exactFields(object, kind.fields, at: "")
        return try kind.decode(object, data)
    }

    private static func request(_ record: Record<RequestWire>) throws -> TelemetryEvent {
        let (identity, wire) = (record.identity, record.body)
        if (wire.context.used ?? 0) < 0 || (wire.context.maximum ?? 0) < 0 {
            throw EventError.malformed("context: negative tokens")
        }
        if let percentage = wire.context.percentage, !(0...100).contains(percentage) {
            throw EventError.malformed("context.percentage: out of range")
        }
        return TelemetryEvent(
            eventID: identity.event_id,
            sequence: identity.sequence,
            routingID: identity.routing_id,
            lineageRootID: identity.lineage_root_id,
            previousSessionID: identity.previous_session_id,
            sessionID: identity.session_id,
            timestamp: try date(identity.timestamp, "timestamp"),
            profile: identity.profile,
            model: wire.model,
            provider: wire.provider,
            state: wire.state,
            context: ContextOccupancy(
                used: wire.context.used,
                maximum: wire.context.maximum,
                percentage: wire.context.percentage,
                source: wire.context.source,
                measuredAt: try wire.context.measured_at.map { try date($0, "context.measured_at") }
            )
        )
    }

    private static func toolCall(_ record: Record<ToolCallWire>) throws -> ToolCallEvent {
        let (identity, wire) = (record.identity, record.body)
        guard !wire.tool_name.isEmpty else { throw EventError.malformed("tool_name: empty") }
        guard wire.skill_name?.isEmpty != true else { throw EventError.malformed("skill_name: empty") }
        guard wire.request_event_id.map(SnapshotDecoder.isIdentity) != false else {
            throw EventError.malformed("request_event_id: not a v1 identity")
        }
        guard wire.estimated_tokens >= 0, wire.duration_ms >= 0 else {
            throw EventError.malformed("estimated_tokens or duration_ms: negative")
        }
        return ToolCallEvent(
            eventID: identity.event_id,
            sequence: identity.sequence,
            routingID: identity.routing_id,
            lineageRootID: identity.lineage_root_id,
            previousSessionID: identity.previous_session_id,
            sessionID: identity.session_id,
            requestEventID: wire.request_event_id,
            timestamp: try date(identity.timestamp, "timestamp"),
            profile: identity.profile,
            toolName: wire.tool_name,
            skillName: wire.skill_name,
            estimatedTokens: wire.estimated_tokens,
            durationMS: wire.duration_ms,
            status: wire.status
        )
    }

    /// One decode of the file for both its identity and its kind's fields, then the checks every kind shares.
    private static func decodeRecord<Body: Decodable>(_ data: Data) throws -> Record<Body> {
        let record: Record<Body>
        do {
            record = try JSONDecoder().decode(Record<Body>.self, from: data)
        } catch let error as DecodingError {
            throw EventError.malformed(reason(error))
        }
        let identity = record.identity
        guard SnapshotDecoder.isIdentity(identity.event_id) else { throw EventError.malformed("event_id: not a v1 identity") }
        guard SnapshotDecoder.isIdentity(identity.routing_id) else { throw EventError.malformed("routing_id: not a v1 identity") }
        guard !identity.lineage_root_id.isEmpty, !identity.session_id.isEmpty, !identity.profile.isEmpty else {
            throw EventError.malformed("lineage_root_id, session_id or profile: empty")
        }
        guard identity.sequence >= 1 else { throw EventError.malformed("sequence: not positive") }
        return record
    }

    private static func date(_ value: String, _ field: String) throws -> Date {
        do { return try SnapshotDecoder.parseTimestamp(value) } catch { throw EventError.malformed("\(field): not a date-time") }
    }

    /// Unknown fields are counted, not named: a key is file content too.
    private static func exactFields(_ object: [String: Any], _ allowed: Set<String>, at path: String) throws {
        let unknown = Set(object.keys).subtracting(allowed).count
        if unknown > 0 { throw EventError.malformed("\(unknown) unapproved field\(unknown == 1 ? "" : "s")") }
        if let missing = allowed.subtracting(object.keys).sorted().first { throw EventError.malformed("\(path)\(missing): missing") }
    }

    /// `context.used: wrong type`: the field path, then a reason that never echoes the value. Keys are already
    /// exact, so a key cannot be missing here.
    private static func reason(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context): "\(SnapshotDecoder.path(context.codingPath)): wrong type"
        case .dataCorrupted(let context): "\(SnapshotDecoder.path(context.codingPath)): invalid value"
        default: "invalid event"
        }
    }

    /// A record's shared identity and its kind's own fields, read from the same JSON object.
    private struct Record<Body: Decodable>: Decodable {
        let identity: IdentityWire
        let body: Body

        init(from decoder: Decoder) throws {
            identity = try IdentityWire(from: decoder)
            body = try Body(from: decoder)
        }
    }

    /// The v1 identity every event kind carries, field for field (`contract_version` and `kind` are checked first).
    private struct IdentityWire: Decodable {
        let event_id: String
        let sequence: Int
        let routing_id: String
        let lineage_root_id: String
        let previous_session_id: String?
        let session_id: String
        let timestamp: String
        let profile: String
    }

    /// The v1 model-request fields.
    private struct RequestWire: Decodable {
        let model: String?
        let provider: String?
        let state: SessionState
        let context: Context

        struct Context: Decodable {
            let used: Int?
            let maximum: Int?
            let percentage: Double?
            let source: String?
            let measured_at: String?
        }
    }

    /// The v1 tool-call fields.
    private struct ToolCallWire: Decodable {
        let request_event_id: String?
        let tool_name: String
        let skill_name: String?
        let estimated_tokens: Int
        let duration_ms: Int
        let status: ToolCallEvent.Status
    }
}
