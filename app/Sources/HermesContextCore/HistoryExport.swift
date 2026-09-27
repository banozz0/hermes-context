import Foundation

/// CSV and JSON exports of the history's approved telemetry: every model-request observation and every tool call,
/// under the database's field names and nothing else. Timestamps are UTC ISO 8601 with milliseconds
/// (`2026-09-24T10:00:30.000Z`). JSON null is an empty CSV cell.
public enum HistoryExport {
    public enum Format: String, Sendable { case csv, json }

    public struct Field: Equatable, Sendable, Encodable {
        public let name: String
        public let meaning: String
    }

    public static let requestFields = requestColumns.map(\.field)
    public static let toolCallFields = toolCallColumns.map(\.field)
    /// `kind`, then every request field, then the tool-call fields a request lacks. A column a row's kind lacks is empty.
    public static let csvColumns = ["kind"] + requestFields.map(\.name)
        + toolCallFields.map(\.name).filter { name in !requestFields.contains { $0.name == name } }

    public static func data(_ format: Format, requests: [TelemetryEvent], toolCalls: [ToolCallEvent], exportedAt: Date = Date()) throws -> Data {
        switch format {
        case .csv: return csv(requests: requests, toolCalls: toolCalls)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(Document(
                exported_at: TelemetryStore.timestampText(exportedAt),
                fields: ["requests": requestFields, "tool_calls": toolCallFields],
                requests: requests.map { row($0, requestColumns) },
                tool_calls: toolCalls.map { row($0, toolCallColumns) }
            ))
        }
    }

    /// RFC 4180: CRLF lines, and a cell holding a comma, quote or line break is quoted with its quotes doubled.
    /// Rows run in event order, both kinds interleaved.
    private static func csv(requests: [TelemetryEvent], toolCalls: [ToolCallEvent]) -> Data {
        func rows<Record: LaneEvent>(_ records: [Record], _ columns: [Column<Record>], kind: String) -> [(key: (Date, String, Int), values: [String: Value])] {
            records.map { (($0.timestamp, $0.profile, $0.sequence), row($0, columns).merging(["kind": .text(kind)]) { $1 }) }
        }
        let lines = (rows(requests, requestColumns, kind: "model_request") + rows(toolCalls, toolCallColumns, kind: "tool_call"))
            .sorted { $0.key < $1.key }
            .map { record in csvColumns.map { record.values[$0]?.csv ?? "" } }
        return Data(([csvColumns] + lines).map { $0.map(cell).joined(separator: ",") + "\r\n" }.joined().utf8)
    }

    private static func cell(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func row<Record>(_ record: Record, _ columns: [Column<Record>]) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: columns.map { ($0.field.name, $0.value(record)) })
    }

    private struct Document: Encodable {
        let format = "hermes-context.history.v1"
        let exported_at: String
        let timestamps = "UTC, ISO 8601 with milliseconds"
        let fields: [String: [Field]]
        let requests: [[String: Value]]
        let tool_calls: [[String: Value]]
    }

    enum Value: Encodable {
        case text(String?), integer(Int?), number(Double?)

        var csv: String {
            switch self {
            case .text(let text): text ?? ""
            case .integer(let number): number.map(String.init) ?? ""
            case .number(let number): number.map { "\($0)" } ?? ""
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text?): try container.encode(text)
            case .integer(let number?): try container.encode(number)
            case .number(let number?): try container.encode(number)
            default: try container.encodeNil()
            }
        }
    }

    /// One exported field: its name, what it means, and how a record fills it.
    struct Column<Record>: Sendable {
        let field: Field
        let value: @Sendable (Record) -> Value

        init(_ name: String, _ meaning: String, _ value: @escaping @Sendable (Record) -> Value) {
            field = Field(name: name, meaning: meaning)
            self.value = value
        }
    }

    private static func shared<Record: LaneEvent>() -> [Column<Record>] {
        [
            Column("event_id", "The event's v1 identity (hc1: and SHA-256); unique across the history.") { .text($0.eventID) },
            Column("profile", "Hermes profile that published the event.") { .text($0.profile) },
            Column("sequence", "The profile's event sequence number, shared by both kinds.") { .integer($0.sequence) },
            Column("routing_id", "Routing lane: profile, platform and Discord location (hc1: and SHA-256).") { .text($0.routingID) },
            Column("lineage_root_id", "First session ID of the lane's lineage.") { .text($0.lineageRootID) },
            Column("previous_session_id", "Session ID this generation replaced; null for a lineage's first.") { .text($0.previousSessionID) },
            Column("session_id", "Hermes session ID; routing_id and session_id together name one generation.") { .text($0.sessionID) },
            Column("timestamp", "When the model request or tool call completed, UTC.") { .text(TelemetryStore.timestampText($0.timestamp)) },
        ]
    }

    static let requestColumns: [Column<TelemetryEvent>] = shared() + [
        Column("model", "Model display identity; null when Hermes named none.") { .text($0.model) },
        Column("provider", "Provider display identity; null when Hermes named none.") { .text($0.provider) },
        Column("state", "working, needs_attention or idle when the request completed.") { .text($0.state.rawValue) },
        Column("context_used", "Prompt tokens in context; null when unknown.") { .integer($0.context.used) },
        Column("context_maximum", "Context window in tokens; null when unknown.") { .integer($0.context.maximum) },
        Column("context_percentage", "context_used as a percentage of context_maximum, 0 to 100; null when unknown.") {
            .number($0.context.percentage)
        },
        Column("context_source", "provider_reported, else the estimate's source; null when unknown.") { .text($0.context.source) },
        Column("context_measured_at", "When occupancy was measured, UTC; null when unknown.") {
            .text($0.context.measuredAt.map(TelemetryStore.timestampText))
        },
    ]

    static let toolCallColumns: [Column<ToolCallEvent>] = shared() + [
        Column("request_event_id", "event_id of the model request that issued the call; null when Hermes named none.") {
            .text($0.requestEventID)
        },
        Column("tool_name", "The tool's name.") { .text($0.toolName) },
        Column("skill_name", "The skill a successful skill_view loaded; null for every other call.") { .text($0.skillName) },
        Column("estimated_tokens", "Hermes's rough token estimate of the call's result, never a provider count.") {
            .integer($0.estimatedTokens)
        },
        Column("duration_ms", "Run time in milliseconds.") { .integer($0.durationMS) },
        Column("status", "ok or error.") { .text($0.status.rawValue) },
    ]
}

/// What both event kinds carry: identity, place in a lane and completion time.
protocol LaneEvent: Sendable {
    var eventID: String { get }
    var sequence: Int { get }
    var routingID: String { get }
    var lineageRootID: String { get }
    var previousSessionID: String? { get }
    var sessionID: String { get }
    var timestamp: Date { get }
    var profile: String { get }
}

extension TelemetryEvent: LaneEvent {}
extension ToolCallEvent: LaneEvent {}
