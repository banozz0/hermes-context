import Foundation
import SQLite3
import Testing
@testable import HermesContextCore

/// A throwaway Hermes root holding the replay fixture's event files, and a throwaway database inside it.
struct Bench {
    let root: URL
    let database: URL
    var location: BridgeLocation { BridgeLocation(root: root) }

    /// The database sits under `app/`, where no Hermes home or event directory can be.
    init(fixture: Bool = true) throws {
        root = try Fixtures.hermesRoot([:])
        database = root.appendingPathComponent("app/telemetry.sqlite")
        guard fixture else { return }
        for (profile, events) in try Fixtures.replayEvents() {
            for event in events { try Fixtures.publish(event, profile: profile, root: root) }
        }
    }

    /// A fresh store on the same file: what the app sees after a relaunch.
    func open() throws -> TelemetryStore { try TelemetryStore(url: database) }

    func publish(_ event: [String: Any], profile: String?, segment: String = "000001", body: Data? = nil) throws {
        try Fixtures.publish(event, profile: profile, root: root, segment: segment, body: body)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Every row of a read-only query against the database file, as text.
    func rows(_ sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return rows
    }
}

private extension TelemetryRecord {
    var request: TelemetryEvent? { if case .request(let event) = self { event } else { nil } }
    var toolCall: ToolCallEvent? { if case .toolCall(let call) = self { call } else { nil } }
}

@Suite struct TelemetryStoreTests {
    @Test func firstImportStoresEveryFixtureEventOnce() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let store = try bench.open()

        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 8))
        let fixture = try Fixtures.replayEvents().values.joined()
            .map { try EventDecoder.decode(JSONSerialization.data(withJSONObject: $0)) }
        let requests = fixture.compactMap(\.request).sorted { $0.timestamp < $1.timestamp }
        let calls = fixture.compactMap(\.toolCall).sorted { $0.timestamp < $1.timestamp }
        #expect(try store.observations() == requests)
        #expect(try store.toolCalls() == calls)
        #expect(requests.map(\.sessionID) == ["alpha-1", "beta-1", "alpha-3"])
        #expect(calls.count == 5)
        #expect(try store.observations()[1].context == ContextOccupancy(used: nil, maximum: nil, percentage: nil, source: nil, measuredAt: nil))
        #expect(try store.issues().isEmpty)
    }

    /// Each call names the request that issued it and sits in that request's generation, including a late call
    /// from a generation `/new` had already replaced.
    @Test func toolCallsLinkToTheirRequestAndGeneration() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let store = try bench.open()
        try store.importEvents(from: bench.location)

        let calls = try store.toolCalls()
        #expect(calls.map { "\($0.profile) \($0.sessionID) \($0.toolName) \($0.skillName ?? "-") \($0.status.rawValue)" } == [
            "alpha alpha-1 skill_view writing ok", "alpha alpha-1 terminal - ok", "beta beta-1 read_file - error",
            "alpha alpha-1 terminal - ok", "alpha alpha-3 skill_view research ok",
        ])
        #expect(calls.map(\.estimatedTokens) == [900, 120, 30, 0, 2400])
        let requests = Dictionary(uniqueKeysWithValues: try store.observations().map { ($0.eventID, $0) })
        for call in calls {
            let requestID = try #require(call.requestEventID)
            let request = try #require(requests[requestID])
            #expect([request.routingID, request.sessionID, request.lineageRootID] == [call.routingID, call.sessionID, call.lineageRootID])
        }
        let generations = Set(try store.lineages().flatMap { lane in lane.generations.map { "\(lane.routingID) \($0.sessionID)" } })
        #expect(Set(calls.map { "\($0.routingID) \($0.sessionID)" }) == generations)
    }

    @Test func replayAndRelaunchNeverDuplicate() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let store = try bench.open()
        try store.importEvents(from: bench.location)

        #expect(try store.importEvents(from: bench.location) == ImportSummary())
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary())
        let request = Fixtures.event(profile: "alpha", sequence: 7, session: "alpha-3")
        try bench.publish(request, profile: "alpha")
        try bench.publish(Fixtures.toolCall(profile: "alpha", sequence: 8, session: "alpha-3", request: request["event_id"] as! String),
                          profile: "alpha")
        let relaunched = try bench.open()
        #expect(try relaunched.importEvents(from: bench.location) == ImportSummary(imported: 2))
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary())
        #expect(try relaunched.observations().count == 4)
        #expect(try relaunched.toolCalls().count == 6)
    }

    /// The event ID is the idempotency boundary: a rebuilt event tree that replays known requests under new
    /// sequence numbers adds only the requests the database has never seen.
    @Test func republishedHistoryDedupesByEventID() throws {
        let bench = try Bench()
        defer { bench.remove() }
        try bench.open().importEvents(from: bench.location)

        try FileManager.default.removeItem(at: bench.root.appendingPathComponent("profiles/alpha/\(BridgeLocation.eventsSuffix)"))
        try bench.publish(Fixtures.event(profile: "alpha", sequence: 1, session: "alpha-9"), profile: "alpha")
        for (offset, original) in try #require(Fixtures.replayEvents()["alpha"]).enumerated() {
            var event = original
            event["sequence"] = offset + 2
            try bench.publish(event, profile: "alpha")
        }
        let store = try bench.open()

        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 1, duplicates: 6, issues: 1))
        #expect(try store.observations().map(\.sessionID) == ["alpha-1", "beta-1", "alpha-3", "alpha-9"])
        #expect(try store.toolCalls().count == 5)
        #expect(try store.issues().map(\.kind) == [.historyReset])
        #expect(try store.skippedRecords().isEmpty, "a rebuilt tree skips nothing")
        #expect(try store.importEvents(from: bench.location) == ImportSummary())
    }

    @Test func interruptedBatchResumesAfterRelaunch() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        for sequence in 1...5 {
            try bench.publish(Fixtures.event(profile: "alpha", sequence: sequence, session: "alpha-1"), profile: "alpha")
        }
        struct Crash: Error {}
        let store = try bench.open()
        var inserted = 0
        store.interruption = { _ in
            inserted += 1
            if inserted == 3 { throw Crash() }
        }

        #expect(throws: Crash.self) { try store.importEvents(from: bench.location, batchSize: 2) }
        // The first batch committed with its cursor; the interrupted batch rolled back whole.
        #expect(try store.observations().map(\.sequence) == [1, 2])
        let relaunched = try bench.open()
        // No duplicates read: the importer resumed at its cursor instead of rescanning.
        #expect(try relaunched.importEvents(from: bench.location, batchSize: 2) == ImportSummary(imported: 3))
        #expect(try relaunched.observations().map(\.sequence) == [1, 2, 3, 4, 5])
    }

    @Test func gapsAndRejectedRecordsSurfaceWithoutBlockingLaterEvents() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        let sentinel = "PROMPT-SENTINEL-7f3a"
        func alpha(_ sequence: Int, _ edit: (inout [String: Any]) -> Void = { _ in }) throws {
            var event = Fixtures.event(profile: "alpha", sequence: sequence, session: "alpha-1")
            edit(&event)
            try bench.publish(event, profile: "alpha")
        }
        try alpha(1)
        try alpha(3)  // 2 never arrives
        try alpha(4) { $0["contract_version"] = "hermes-context.v2" }
        try alpha(5) { $0["current_tool"] = "terminal"; $0["prompt"] = sentinel }
        try alpha(6) { $0["state"] = sentinel }
        try alpha(7) { $0["profile"] = "beta" }
        try alpha(8)
        try bench.publish(Fixtures.event(profile: "beta", sequence: 1, session: "beta-1"), profile: "beta", body: Data("{\"contract_version\":".utf8))
        try bench.publish(Fixtures.event(profile: "beta", sequence: 2, session: "beta-1"), profile: "beta")
        let store = try bench.open()

        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 4, issues: 6))
        #expect(try store.observations().map { "\($0.profile)#\($0.sequence)" } == ["alpha#1", "alpha#3", "alpha#8", "beta#2"])
        let issues = try store.issues()
        #expect(issues.map { "\($0.profile)#\($0.sequences) \($0.kind.rawValue)" } == [
            "alpha#2...2 gap", "alpha#4...4 unsupported", "alpha#5...5 malformed", "alpha#6...6 malformed",
            "alpha#7...7 malformed", "beta#1...1 malformed",
        ])
        #expect(issues[2].detail == "2 unapproved fields")
        #expect(issues[4].detail == "profile does not match its Hermes home")
        #expect(issues[0].file == nil)
        #expect(issues[2].file?.hasPrefix("000001/000000000005-hc1:") == true)
        #expect(try store.skippedRecords() == ["alpha": 5, "beta": 1])
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary())
        // No rejected record's contents reach the database, its log or its WAL.
        for suffix in ["", "-wal", "-shm"] {
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: bench.database.path + suffix))) ?? Data()
            #expect(bytes.range(of: Data(sentinel.utf8)) == nil)
            #expect(bytes.range(of: Data("terminal".utf8)) == nil)
        }
    }

    /// A tool call keeps only its approved fields. Arguments, a result or an error message in a file reject the
    /// record, and none of it reaches the database, its log or its WAL.
    @Test func toolCallContentNeverReachesTheDatabase() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        let sentinel = "TOOL-SENTINEL-91b2"
        let request = Fixtures.event(profile: "alpha", sequence: 1, session: "alpha-1")
        try bench.publish(request, profile: "alpha")
        func call(_ sequence: Int, _ edit: (inout [String: Any]) -> Void = { _ in }) throws {
            var call = Fixtures.toolCall(profile: "alpha", sequence: sequence, session: "alpha-1", request: request["event_id"] as! String)
            edit(&call)
            try bench.publish(call, profile: "alpha")
        }
        try call(2)
        try call(3) { $0["arguments"] = ["command": sentinel] }
        try call(4) { $0["result"] = sentinel }
        try call(5) { $0["error_message"] = sentinel }
        try call(6) { $0["status"] = sentinel }
        try call(7) { $0["estimated_tokens"] = -1 }
        try call(8) { $0["request_event_id"] = sentinel }
        try call(9) { $0["kind"] = sentinel }
        try call(10) { $0["context"] = request["context"] }
        let store = try bench.open()

        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 2, issues: 8))
        #expect(try store.toolCalls().map(\.sequence) == [2])
        #expect(try store.issues().map(\.detail) == [
            "1 unapproved field", "1 unapproved field", "1 unapproved field", "status: invalid value",
            "estimated_tokens or duration_ms: negative", "request_event_id: not a v1 identity", "kind: invalid value",
            "1 unapproved field",
        ])
        for suffix in ["", "-wal", "-shm"] {
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: bench.database.path + suffix))) ?? Data()
            #expect(bytes.range(of: Data(sentinel.utf8)) == nil)
        }
    }

    /// The observer allocates sequence numbers under a lock, but if two files ever share one, both are valid
    /// events: the cursor orders by (sequence, event ID), so neither is lost across a batch boundary or a relaunch.
    @Test func twoFilesOnOneSequenceNumberAreBothKept() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        let twins = ["alpha-a", "alpha-b"].map { Fixtures.event(profile: "alpha", sequence: 2, session: $0) }
            .sorted { ($0["event_id"] as! String) < ($1["event_id"] as! String) }
        try bench.publish(Fixtures.event(profile: "alpha", sequence: 1, session: "alpha-1"), profile: "alpha")
        try bench.publish(twins[0], profile: "alpha")
        let store = try bench.open()
        #expect(try store.importEvents(from: bench.location, batchSize: 2) == ImportSummary(imported: 2))

        try bench.publish(twins[1], profile: "alpha")  // lands after the cursor passed its sequence number
        try bench.publish(Fixtures.event(profile: "alpha", sequence: 3, session: "alpha-1"), profile: "alpha")
        #expect(try bench.open().importEvents(from: bench.location, batchSize: 1) == ImportSummary(imported: 2))
        #expect(try store.observations().map(\.sequence) == [1, 2, 2, 3])
        #expect(try store.issues().isEmpty)
    }

    /// Rotation opens a new segment directory; the cursor carries across it and never re-lists a closed one.
    @Test func cursorFollowsSegmentRotation() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        func alpha(_ sequence: Int, segment: String) throws {
            try bench.publish(Fixtures.event(profile: "alpha", sequence: sequence, session: "alpha-1"), profile: "alpha", segment: segment)
        }
        for sequence in 1...3 { try alpha(sequence, segment: "000001") }
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary(imported: 3))

        for sequence in 4...5 { try alpha(sequence, segment: "000002") }
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary(imported: 2))
        try alpha(6, segment: "000002")
        let store = try bench.open()
        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 1))
        #expect(try bench.rows("SELECT segment, sequence FROM import_cursors") == [["000002", "6"]])
        #expect(try store.observations().map(\.sequence) == Array(1...6))
        #expect(try store.issues().isEmpty)
    }

    @Test func defaultHomeEventsBelongToTheDefaultProfile() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        try bench.publish(Fixtures.event(profile: "default", sequence: 1, session: "d-1"), profile: nil)
        try bench.publish(Fixtures.event(profile: "alpha", sequence: 2, session: "d-2"), profile: nil)
        let store = try bench.open()

        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 1, issues: 1))
        #expect(try store.observations().map(\.sessionID) == ["d-1"])
    }

    @Test func schemaHoldsOnlyApprovedTelemetry() throws {
        let bench = try Bench()
        defer { bench.remove() }
        try bench.open().importEvents(from: bench.location)

        #expect(try bench.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { $0[0] }
                == ["import_cursors", "ingest_issues", "observations", "tool_calls"])
        let approved = [
            "observations": ["event_id", "profile", "sequence", "routing_id", "lineage_root_id", "previous_session_id",
                             "session_id", "timestamp", "model", "provider", "state", "context_used", "context_maximum",
                             "context_percentage", "context_source", "context_measured_at"],
            "import_cursors": ["profile", "sequence", "event_id", "segment"],
            "ingest_issues": ["profile", "kind", "first_sequence", "last_sequence", "file", "detail", "detected_at"],
            "tool_calls": ["event_id", "profile", "sequence", "routing_id", "lineage_root_id", "previous_session_id", "session_id",
                           "request_event_id", "timestamp", "tool_name", "skill_name", "estimated_tokens", "duration_ms", "status"],
        ]
        for (table, columns) in approved {
            let info = try bench.rows("PRAGMA table_info(\(table))")  // cid, name, type, notnull, default, pk
            #expect(info.map { $0[1] } == columns)
            #expect(info.allSatisfy { ["TEXT", "INTEGER", "REAL"].contains($0[2]) }, "no BLOB or ANY column can carry a payload")
        }
        let forbidden = ["prompt", "message", "response", "reasoning", "preview", "arg", "result", "error", "output", "payload", "json", "raw"]
        #expect(!approved.values.joined().contains { column in forbidden.contains { column.contains($0) } })
        // A tool's name is the one tool column: never a current tool, its arguments, result or error text.
        #expect(approved.values.joined().filter { $0.contains("tool") } == ["tool_name"])
        // Private to the user: the directory, the database and SQLite's own WAL and shared-memory files.
        func mode(_ path: String) throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) }
        #expect(try mode(bench.database.deletingLastPathComponent().path) == 0o700)
        for suffix in ["", "-wal", "-shm"] { #expect(try mode(bench.database.path + suffix) == 0o600) }
    }

    @Test func generationsGroupUnderTheirRoutingLineage() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let replay = try Fixtures.replayEvents()
        let alphaLane = try #require(replay["alpha"]?.first?["routing_id"] as? String)
        let betaLane = try #require(replay["beta"]?.first?["routing_id"] as? String)
        // Cross-thread /resume: alpha-1 answers once more from another alpha thread, under that lane's lineage.
        let resumed = Fixtures.event(profile: "alpha", sequence: 7, session: "alpha-1", root: "alpha-2", previous: "alpha-2",
                                     at: "2026-09-24T10:04:00Z")
        try bench.publish(resumed, profile: "alpha")
        let store = try bench.open()
        try store.importEvents(from: bench.location)

        let lineages = try store.lineages()
        #expect(lineages.map(\.routingID) == [try #require(resumed["routing_id"] as? String), alphaLane, betaLane])
        #expect(lineages.map(\.profile) == ["alpha", "alpha", "beta"])
        let thread = lineages[1].generations
        #expect(thread.map(\.sessionID) == ["alpha-1", "alpha-3"])
        #expect(thread.map(\.previousSessionID) == [nil, "alpha-1"])
        #expect(thread.map(\.lineageRootID) == ["alpha-1", "alpha-1"])
        #expect(thread[1].firstAt == (try SnapshotDecoder.parseTimestamp("2026-09-24T10:02:30Z")))
        let other = lineages[0].generations
        #expect(other.map(\.sessionID) == ["alpha-1"])
        #expect(other.map(\.lineageRootID) == ["alpha-2"])
        #expect(lineages[2].generations.map(\.sessionID) == ["beta-1"])
    }

    /// A history an older app kept (schema 1, requests only) keeps every observation and its cursor; the next import
    /// adds the tool calls published after it and nothing it already had.
    @Test func schemaOneHistoryMigratesInPlace() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        for sequence in 1...2 {
            try bench.publish(Fixtures.event(profile: "alpha", sequence: sequence, session: "alpha-1"), profile: "alpha")
        }
        let before: [TelemetryEvent]
        do {
            let old = try TelemetryStore(url: bench.database, schemaVersion: 1)
            #expect(try old.importEvents(from: bench.location) == ImportSummary(imported: 2))
            before = try old.observations()
        }
        #expect(try bench.rows("PRAGMA user_version") == [["1"]])
        #expect(try bench.rows("SELECT name FROM sqlite_master WHERE name = 'tool_calls'").isEmpty)
        let request = try #require(before.last?.eventID)
        try bench.publish(Fixtures.toolCall(profile: "alpha", sequence: 3, session: "alpha-1", request: request), profile: "alpha")

        let migrated = try bench.open()
        #expect(try bench.rows("PRAGMA user_version") == [["2"]])
        #expect(try migrated.observations() == before)
        #expect(try bench.rows("SELECT sequence FROM import_cursors") == [["2"]])
        #expect(try migrated.importEvents(from: bench.location) == ImportSummary(imported: 1))
        #expect(try migrated.toolCalls().map(\.requestEventID) == [request])
        #expect(try migrated.observations() == before)
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary())
    }

    @Test func databaseFromANewerAppIsRefused() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        _ = try bench.open()
        var db: OpaquePointer?
        #expect(sqlite3_open(bench.database.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(throws: TelemetryStoreError.newerSchema(99)) { try bench.open() }
    }
}
