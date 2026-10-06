import Foundation
import SQLite3

public enum TelemetryStoreError: LocalizedError, Equatable, CustomStringConvertible {
    case sqlite(String)
    /// A newer app wrote this database; this one refuses to guess at its schema.
    case newerSchema(Int)

    public var description: String {
        switch self {
        case .sqlite(let message): "SQLite: \(message)"
        case .newerSchema(let version): "Telemetry database schema \(version) is newer than this app"
        }
    }

    public var errorDescription: String? { description }
}

public struct ImportSummary: Equatable, Sendable {
    public var imported = 0
    /// Events already stored under their event ID, re-read after a rebuilt event tree.
    public var duplicates = 0
    public var issues = 0
}

/// Something the importer stepped over instead of storing. Recorded once, never retried: event files are immutable.
public struct IngestIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Sequence numbers with no event file.
        case gap
        case unsupported
        case malformed
        case unreadable
        /// The file under the saved cursor is gone, so the profile's whole event tree was read again.
        case historyReset = "history_reset"
    }

    public let profile: String
    public let kind: Kind
    public let sequences: ClosedRange<Int>
    /// `<segment>/<sequence>-<event_id>.json` under the profile's events directory; `nil` for a gap.
    public let file: String?
    /// A reason naming fields only, never a value from the file.
    public let detail: String
    public let detectedAt: Date
}

/// One session generation inside a routing lane: its own statistical unit.
public struct Generation: Equatable, Sendable {
    public let sessionID: String
    public let lineageRootID: String
    public let previousSessionID: String?
    public let firstAt: Date
    public let lastAt: Date
}

/// Every generation one profile-plus-Discord-location lane has run, oldest first. A cross-thread `/resume` can
/// put one session ID in two lanes; each lane keeps its own generation for it.
public struct Lineage: Equatable, Sendable, Identifiable {
    public let routingID: String
    public let profile: String
    public let generations: [Generation]

    public var id: String { routingID }
}

/// The app's durable activity history: one row per completed model request and one per completed tool call, imported
/// exactly once from every profile's append-only event files. The event ID is the idempotency boundary; a per-profile cursor, committed
/// with each batch, is what lets a relaunch resume where the last import stopped. Use from one thread at a time.
public final class TelemetryStore {
    static var schemaVersion: Int { migrations.count }
    private let db: OpaquePointer
    /// Test seam: runs after each newly stored record, inside its batch's transaction.
    var interruption: ((TelemetryRecord) throws -> Void)?

    /// The real history: the app's Application Support file.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.banozz0.hermes-context/telemetry.sqlite")
    }

    public convenience init(url: URL) throws {
        try self.init(url: url, schemaVersion: Self.schemaVersion)
    }

    /// Test seam: `schemaVersion` below the current one builds a database as an older app left it.
    init(url: URL, schemaVersion target: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Created private before SQLite opens it; SQLite gives its WAL and shared-memory files the same mode.
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw TelemetryStoreError.sqlite("cannot create \(url.path)")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            throw TelemetryStoreError.sqlite(message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5_000)
        try migrate(to: target)
    }

    deinit { sqlite3_close(db) }

    // MARK: Import

    /// Imports every event published since each profile's cursor. A rejected or missing record becomes an issue
    /// and never blocks the events after it; only a database failure throws, rolling back its batch.
    @discardableResult
    public func importEvents(from location: BridgeLocation, batchSize: Int = 500) throws -> ImportSummary {
        var summary = ImportSummary()
        for source in location.discoverEventDirectories() {
            try importEvents(profile: source.profile, directory: source.directory, batchSize: max(1, batchSize), into: &summary)
        }
        return summary
    }

    private func importEvents(profile: String, directory: URL, batchSize: Int, into summary: inout ImportSummary) throws {
        var cursor = try query("SELECT segment, sequence, event_id FROM import_cursors WHERE profile = ?", [profile]) {
            EventFile(segment: $0.text(0) ?? "", sequence: $0.int(1) ?? 0, eventID: $0.text(2) ?? "")
        }.first
        // Rotation never removes files, so a vanished cursor file means the tree was rebuilt: read it all again
        // and let event IDs drop what is already stored.
        if let lost = cursor, !FileManager.default.fileExists(atPath: directory.appendingPathComponent(lost.path).path) {
            try transaction {
                try run("DELETE FROM import_cursors WHERE profile = ?", [profile])
                summary.issues += try recordIssue(profile, .historyReset, lost.sequence...lost.sequence,
                                                  file: lost.path, detail: "cursor event file is gone; event tree read again")
            }
            cursor = nil
        }
        let pending = EventFile.list(in: directory, after: cursor)
        var expected = (cursor?.sequence ?? 0) + 1
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = pending[start..<min(start + batchSize, pending.count)]
            try transaction {
                for file in batch {
                    if file.sequence > expected {
                        summary.issues += try recordIssue(profile, .gap, expected...(file.sequence - 1), file: nil,
                                                          detail: "no event file for \(file.sequence - expected) sequence number(s)")
                    }
                    // Two files on one sequence number both hold valid events; the event ID keeps them apart.
                    switch try store(file, profile: profile, directory: directory) {
                    case .imported: summary.imported += 1
                    case .duplicate: summary.duplicates += 1
                    case .rejected(let kind, let detail):
                        summary.issues += try recordIssue(profile, kind, file.sequence...file.sequence, file: file.path, detail: detail)
                    }
                    expected = max(expected, file.sequence + 1)
                }
                if let last = batch.last {
                    try run("""
                        INSERT INTO import_cursors (profile, sequence, event_id, segment) VALUES (?, ?, ?, ?)
                        ON CONFLICT (profile) DO UPDATE SET sequence = excluded.sequence, event_id = excluded.event_id,
                            segment = excluded.segment
                        """, [profile, last.sequence, last.eventID, last.segment])
                }
            }
        }
    }

    private enum Outcome {
        case imported, duplicate
        case rejected(IngestIssue.Kind, String)
    }

    /// Reads one file through the production decoder and stores it unless its event ID is already present.
    private func store(_ file: EventFile, profile: String, directory: URL) throws -> Outcome {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent(file.path)) } catch {
            return .rejected(.unreadable, "event file is not readable")
        }
        let record: TelemetryRecord
        do { record = try EventDecoder.decode(data) } catch let error as EventError {
            return .rejected(error == .unsupportedContract ? .unsupported : .malformed, error.description)
        }
        guard record.identity.profile == profile else { return .rejected(.malformed, "profile does not match its Hermes home") }
        guard record.identity.sequence == file.sequence, record.identity.eventID == file.eventID else {
            return .rejected(.malformed, "sequence or event_id does not match the file name")
        }
        switch record {
        case .request(let event):
            try run("""
                INSERT INTO observations (event_id, profile, sequence, routing_id, lineage_root_id, previous_session_id, session_id,
                    timestamp, model, provider, state, context_used, context_maximum, context_percentage, context_source,
                    context_measured_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (event_id) DO NOTHING
                """, [event.eventID, event.profile, event.sequence, event.routingID, event.lineageRootID, event.previousSessionID,
                      event.sessionID, Self.timestampText(event.timestamp), event.model, event.provider, event.state.rawValue,
                      event.context.used, event.context.maximum, event.context.percentage, event.context.source,
                      event.context.measuredAt.map(Self.timestampText)])
        case .toolCall(let call):
            try run("""
                INSERT INTO tool_calls (event_id, profile, sequence, routing_id, lineage_root_id, previous_session_id, session_id,
                    request_event_id, timestamp, tool_name, skill_name, estimated_tokens, duration_ms, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (event_id) DO NOTHING
                """, [call.eventID, call.profile, call.sequence, call.routingID, call.lineageRootID, call.previousSessionID,
                      call.sessionID, call.requestEventID, Self.timestampText(call.timestamp), call.toolName, call.skillName,
                      call.estimatedTokens, call.durationMS, call.status.rawValue])
        }
        guard sqlite3_changes(db) > 0 else { return .duplicate }
        try interruption?(record)
        return .imported
    }

    /// Returns 1 for a new issue and 0 for one already recorded, so a summary counts each issue once.
    private func recordIssue(_ profile: String, _ kind: IngestIssue.Kind, _ sequences: ClosedRange<Int>, file: String?,
                             detail: String) throws -> Int {
        try run("""
            INSERT INTO ingest_issues (profile, kind, first_sequence, last_sequence, file, detail, detected_at)
            VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
            """, [profile, kind.rawValue, sequences.lowerBound, sequences.upperBound, file ?? "", detail, Self.timestampText(Date())])
        return Int(sqlite3_changes(db))
    }

    // MARK: Reads

    /// Every stored observation, oldest first.
    public func observations() throws -> [TelemetryEvent] {
        try query("""
            SELECT event_id, sequence, routing_id, lineage_root_id, previous_session_id, session_id, timestamp, profile, model,
                provider, state, context_used, context_maximum, context_percentage, context_source, context_measured_at
            FROM observations ORDER BY timestamp, profile, sequence
            """) { row in
            guard let state = SessionState(rawValue: row.text(10) ?? "") else { throw TelemetryStoreError.sqlite("invalid state") }
            return TelemetryEvent(
                eventID: row.text(0) ?? "", sequence: row.int(1) ?? 0, routingID: row.text(2) ?? "", lineageRootID: row.text(3) ?? "",
                previousSessionID: row.text(4), sessionID: row.text(5) ?? "", timestamp: try row.date(6), profile: row.text(7) ?? "",
                model: row.text(8), provider: row.text(9), state: state,
                context: ContextOccupancy(used: row.int(11), maximum: row.int(12), percentage: row.double(13), source: row.text(14),
                                          measuredAt: try row.text(15).map(SnapshotDecoder.parseTimestamp))
            )
        }
    }

    /// Every stored tool call, oldest first. `requestEventID` names its model request's observation, and
    /// `(routingID, sessionID)` its generation.
    public func toolCalls() throws -> [ToolCallEvent] {
        try query("""
            SELECT event_id, sequence, routing_id, lineage_root_id, previous_session_id, session_id, request_event_id, timestamp,
                profile, tool_name, skill_name, estimated_tokens, duration_ms, status
            FROM tool_calls ORDER BY timestamp, profile, sequence
            """) { row in
            guard let status = ToolCallEvent.Status(rawValue: row.text(13) ?? "") else { throw TelemetryStoreError.sqlite("invalid status") }
            return ToolCallEvent(
                eventID: row.text(0) ?? "", sequence: row.int(1) ?? 0, routingID: row.text(2) ?? "", lineageRootID: row.text(3) ?? "",
                previousSessionID: row.text(4), sessionID: row.text(5) ?? "", requestEventID: row.text(6), timestamp: try row.date(7),
                profile: row.text(8) ?? "", toolName: row.text(9) ?? "", skillName: row.text(10), estimatedTokens: row.int(11) ?? 0,
                durationMS: row.int(12) ?? 0, status: status
            )
        }
    }

    /// Lanes with the most recent activity first. A generation's root and predecessor come from its first request.
    public func lineages() throws -> [Lineage] {
        let rows = try query("""
            SELECT routing_id, profile, session_id, lineage_root_id, previous_session_id, first_at, last_at FROM (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY routing_id, session_id ORDER BY timestamp, sequence) AS position,
                    MIN(timestamp) OVER generation AS first_at, MAX(timestamp) OVER generation AS last_at
                FROM observations WINDOW generation AS (PARTITION BY routing_id, session_id)
            ) WHERE position = 1 ORDER BY routing_id, first_at, session_id
            """) { row in
            (routing: row.text(0) ?? "", profile: row.text(1) ?? "",
             generation: Generation(sessionID: row.text(2) ?? "", lineageRootID: row.text(3) ?? "", previousSessionID: row.text(4),
                                    firstAt: try row.date(5), lastAt: try row.date(6)))
        }
        return Dictionary(grouping: rows, by: { $0.routing }).map { routing, rows in
            Lineage(routingID: routing, profile: rows[0].profile, generations: rows.map { $0.generation })
        }.sorted {
            let (left, right) = ($0.generations.map(\.lastAt).max()!, $1.generations.map(\.lastAt).max()!)
            return left != right ? left > right : $0.routingID < $1.routingID
        }
    }

    /// The Insights statistics over every stored observation: four columns per request, no dates parsed.
    public func insights() throws -> InsightsReport {
        let requests = try query("SELECT profile, routing_id, session_id, context_percentage FROM observations") {
            InsightsReport.Request(profile: $0.text(0) ?? "",
                                   generation: .init(routingID: $0.text(1) ?? "", sessionID: $0.text(2) ?? ""), percentage: $0.double(3))
        }
        return InsightsReport(requests: requests, lineages: try lineages(),
                              toolCalls: try query("SELECT COUNT(*) FROM tool_calls") { $0.int(0) ?? 0 }.first ?? 0)
    }

    /// Event records each profile's history is missing because they were absent, rejected or unreadable. A gap
    /// counts every sequence number it spans; a rebuilt event tree skips nothing.
    public func skippedRecords() throws -> [String: Int] {
        Dictionary(uniqueKeysWithValues: try query("""
            SELECT profile, SUM(last_sequence - first_sequence + 1) FROM ingest_issues
            WHERE kind != 'history_reset' GROUP BY profile
            """) { ($0.text(0) ?? "", $0.int(1) ?? 0) })
    }

    /// Everything the importer stepped over, per profile in sequence order.
    public func issues() throws -> [IngestIssue] {
        try query("""
            SELECT profile, kind, first_sequence, last_sequence, file, detail, detected_at
            FROM ingest_issues ORDER BY profile, first_sequence, kind
            """) { row in
            guard let kind = IngestIssue.Kind(rawValue: row.text(1) ?? "") else { throw TelemetryStoreError.sqlite("invalid issue kind") }
            return IngestIssue(profile: row.text(0) ?? "", kind: kind, sequences: (row.int(2) ?? 0)...(row.int(3) ?? 0),
                               file: row.text(4).flatMap { $0.isEmpty ? nil : $0 }, detail: row.text(5) ?? "", detectedAt: try row.date(6))
        }
    }

    // MARK: Clear

    /// Imports what `location` has published, so the clear covers everything up to now, then deletes every observation,
    /// tool call and skipped-record issue in one transaction and rebuilds the file and empties its WAL so no deleted row
    /// survives on disk. The import cursors stay: event files are never pruned, so without them the next import would
    /// read the whole history back. Nothing outside this database is written.
    public func clearHistory(importingFrom location: BridgeLocation) throws {
        try importEvents(from: location)
        try transaction {
            for table in ["observations", "tool_calls", "ingest_issues"] { try run("DELETE FROM \(table)") }
        }
        try run("VACUUM")
        // A checkpoint that another connection blocks reports it in a row, not as an error.
        guard try query("PRAGMA wal_checkpoint(TRUNCATE)", [], { $0.int(0) }).first == 0 else {
            throw TelemetryStoreError.sqlite("history cleared, but another connection blocked the checkpoint that removes its deleted pages")
        }
    }

    // MARK: Schema

    /// Approved telemetry only: no column exists for a current tool, a message, a prompt, a response, reasoning,
    /// tool arguments, results or error text, and no column can hold a serialized payload. STRICT tables enforce the
    /// types. Migration N brings a database from `user_version` N-1 to N; a shipped step never changes.
    private static let migrations = [
        """
        CREATE TABLE observations (
            event_id TEXT NOT NULL PRIMARY KEY,
            profile TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence >= 1),
            routing_id TEXT NOT NULL,
            lineage_root_id TEXT NOT NULL,
            previous_session_id TEXT,
            session_id TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            model TEXT,
            provider TEXT,
            state TEXT NOT NULL CHECK (state IN ('working', 'needs_attention', 'idle')),
            context_used INTEGER CHECK (context_used >= 0),
            context_maximum INTEGER CHECK (context_maximum >= 0),
            context_percentage REAL CHECK (context_percentage BETWEEN 0 AND 100),
            context_source TEXT,
            context_measured_at TEXT
        ) STRICT;
        CREATE INDEX observations_by_generation ON observations (routing_id, session_id, timestamp);
        CREATE INDEX observations_by_time ON observations (timestamp, profile, sequence);
        CREATE TABLE import_cursors (
            profile TEXT NOT NULL PRIMARY KEY,
            sequence INTEGER NOT NULL,
            event_id TEXT NOT NULL,
            segment TEXT NOT NULL
        ) STRICT;
        CREATE TABLE ingest_issues (
            profile TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('gap', 'unsupported', 'malformed', 'unreadable', 'history_reset')),
            first_sequence INTEGER NOT NULL,
            last_sequence INTEGER NOT NULL,
            file TEXT NOT NULL,
            detail TEXT NOT NULL,
            detected_at TEXT NOT NULL,
            PRIMARY KEY (profile, kind, first_sequence, last_sequence, file)
        ) STRICT;
        """,
        // 2: tool usage. Observations, cursors and issues carry over untouched; tool-call files already behind a
        // cursor were never published before this schema, so nothing needs re-reading.
        """
        CREATE TABLE tool_calls (
            event_id TEXT NOT NULL PRIMARY KEY,
            profile TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence >= 1),
            routing_id TEXT NOT NULL,
            lineage_root_id TEXT NOT NULL,
            previous_session_id TEXT,
            session_id TEXT NOT NULL,
            request_event_id TEXT,
            timestamp TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            skill_name TEXT,
            estimated_tokens INTEGER NOT NULL CHECK (estimated_tokens >= 0),
            duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
            status TEXT NOT NULL CHECK (status IN ('ok', 'error'))
        ) STRICT;
        CREATE INDEX tool_calls_by_time ON tool_calls (timestamp, profile, sequence);
        """,
    ]

    private func migrate(to target: Int) throws {
        let version = try query("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
        guard version <= Self.schemaVersion else { throw TelemetryStoreError.newerSchema(version) }
        // WAL keeps a reader unblocked by an import; NORMAL can lose only a last batch, whose cursor goes with it.
        try run("PRAGMA journal_mode = WAL")
        try run("PRAGMA synchronous = NORMAL")
        for step in stride(from: version + 1, through: target, by: 1) {
            try transaction {
                try check(sqlite3_exec(db, Self.migrations[step - 1], nil, nil, nil))
                try run("PRAGMA user_version = \(step)")
            }
        }
    }

    // MARK: SQLite

    /// UTC with milliseconds (`2026-09-24T10:00:30.000Z`): unambiguous, and sorts as text in time order.
    static func timestampText(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func check(_ code: Int32) throws {
        guard [SQLITE_OK, SQLITE_ROW, SQLITE_DONE].contains(code) else {
            throw TelemetryStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func run(_ sql: String, _ values: [Any?] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Any?] = [], _ read: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: try check(sqlite3_bind_text(statement, index, text, -1, transient))
            case let number as Int: try check(sqlite3_bind_int64(statement, index, Int64(number)))
            case let number as Double: try check(sqlite3_bind_double(statement, index, number))
            default: try check(sqlite3_bind_null(statement, index))
            }
        }
        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                try check(code)
                return rows
            }
            rows.append(try read(Row(statement: statement)))
        }
    }

    private struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
        }

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func date(_ column: Int32) throws -> Date {
            try SnapshotDecoder.parseTimestamp(text(column) ?? "")
        }
    }
}
