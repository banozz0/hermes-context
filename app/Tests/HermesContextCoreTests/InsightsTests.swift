import Foundation
import SQLite3
import Testing
@testable import HermesContextCore

/// Insights statistics, export and clear, through the real importer on a throwaway Hermes root and database.
@Suite struct InsightsTests {
    static let laneA = Fixtures.identity("alpha/lane-a")
    static let laneB = Fixtures.identity("alpha/lane-b")
    static let laneC = Fixtures.identity("beta/lane-c")

    /// Fixed observations whose statistics check by hand. Context percentage is `used / 10`; nil is an unknown occupancy.
    ///
    /// | lane | generation | percentages       | requests | measured | mean | median | peak |
    /// | A    | a1         | 10, 20, 60        | 3        | 3        | 30   | 20     | 60   |
    /// | A    | a2 (/new)  | 25, 35            | 2        | 2        | 30   | 30     | 35   |
    /// | B    | b1         | nil, 45           | 2        | 1        | 45   | 45     | 45   |
    /// | C    | c1         | 15                | 1        | 1        | 15   | 15     | 15   |
    /// | C    | c2 (/new)  | nil               | 1        | 0        | -    | -      | -    |
    ///
    /// alpha: 10 20 25 35 45 60, so 7 requests, 6 measured, mean 195 / 6 = 32.5, median (25 + 35) / 2 = 30, peak 60.
    /// beta: 1 measured of 2, all 15. Overall: 10 15 20 25 35 45 60, so 9 requests, 7 measured, mean 210 / 7 = 30,
    /// median 25, peak 60. a1 sat at 20% for an hour: time-weighting would put its mean near 20, not 30.
    static func publishFixedObservations(_ bench: Bench) throws {
        func request(_ profile: String, _ sequence: Int, _ session: String, lane: String, root: String, previous: String? = nil,
                     at time: String, used: Int?) throws {
            try bench.publish(Fixtures.event(profile: profile, sequence: sequence, session: session, routing: lane, root: root,
                                             previous: previous, at: "2026-09-24T\(time)Z", used: used), profile: profile)
        }
        try request("alpha", 1, "a1", lane: laneA, root: "a1", at: "10:00:00", used: 100)
        try request("alpha", 2, "a1", lane: laneA, root: "a1", at: "10:00:01", used: 200)
        try request("alpha", 3, "a1", lane: laneA, root: "a1", at: "11:00:00", used: 600)
        try request("alpha", 4, "a2", lane: laneA, root: "a1", previous: "a1", at: "11:05:00", used: 250)
        try request("alpha", 5, "a2", lane: laneA, root: "a1", previous: "a1", at: "11:06:00", used: 350)
        try request("alpha", 6, "b1", lane: laneB, root: "b1", at: "11:10:00", used: nil)
        try request("alpha", 7, "b1", lane: laneB, root: "b1", at: "11:11:00", used: 450)
        try request("beta", 1, "c1", lane: laneC, root: "c1", at: "10:30:00", used: 150)
        try request("beta", 2, "c2", lane: laneC, root: "c1", previous: "c1", at: "10:40:00", used: nil)
    }

    /// `requests measured mean median peak`, with `-` for no measurement.
    static func line(_ value: ContextStatistics) -> String {
        [value.requests, value.measured].map(String.init).joined(separator: " ") + " "
            + [value.mean, value.median, value.peak].map { $0.map { "\($0)" } ?? "-" }.joined(separator: " ")
    }

    @Test func statisticsAreExactPerGenerationProfileAndOverall() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        try Self.publishFixedObservations(bench)
        let store = try bench.open()
        try store.importEvents(from: bench.location)
        let report = try store.insights()

        #expect(Self.line(report.overall) == "9 7 30.0 25.0 60.0")
        #expect(report.profiles.map { "\($0.profile): \(Self.line($0.statistics))" } == ["alpha: 7 6 32.5 30.0 60.0", "beta: 2 1 15.0 15.0 15.0"])
        #expect(report.lanes.map(\.routingID) == [Self.laneB, Self.laneA, Self.laneC], "most recent lane first")
        #expect(report.lanes.map { $0.generations.map { "\($0.id): \(Self.line($0.statistics))" } } == [
            ["b1: 2 1 45.0 45.0 45.0"],
            ["a1: 3 3 30.0 20.0 60.0", "a2: 2 2 30.0 30.0 35.0"],
            ["c1: 1 1 15.0 15.0 15.0", "c2: 1 0 - - -"],
        ])
        #expect(report.lanes[1].generations.map(\.generation.previousSessionID) == [nil, "a1"])
        #expect(report.toolCalls == 0)
    }

    @Test func medianTakesTheMiddleOrTheMeanOfTheTwoMiddles() {
        #expect(Self.line(ContextStatistics([])) == "0 0 - - -")
        #expect(Self.line(ContextStatistics([nil, nil])) == "2 0 - - -")
        #expect(Self.line(ContextStatistics([30, 10, 20])) == "3 3 20.0 20.0 30.0", "unsorted input")
        #expect(Self.line(ContextStatistics([4, 1, 3, 2])) == "4 4 2.5 2.5 4.0")
        #expect(Self.line(ContextStatistics([0, 100, 100, nil])) == "4 3 \(200.0 / 3) 100.0 100.0")
    }

    // MARK: Export

    static let sharedFields = ["event_id", "profile", "sequence", "routing_id", "lineage_root_id", "previous_session_id", "session_id", "timestamp"]
    static let requestFields = sharedFields + ["model", "provider", "state", "context_used", "context_maximum", "context_percentage",
                                               "context_source", "context_measured_at"]
    static let toolCallFields = sharedFields + ["request_event_id", "tool_name", "skill_name", "estimated_tokens", "duration_ms", "status"]
    static var timestamp: Regex<Substring> { /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/ }

    /// The replay fixture plus one request whose model name needs CSV quoting.
    static func exportBench() throws -> (Bench, TelemetryStore) {
        let bench = try Bench()
        var awkward = Fixtures.event(profile: "beta", sequence: 3, session: "beta-1", at: "2026-09-24T10:04:00Z")
        awkward["model"] = "model \"q\", with\nbreak"
        try bench.publish(awkward, profile: "beta")
        let store = try bench.open()
        try store.importEvents(from: bench.location)
        return (bench, store)
    }

    @Test func exportFieldsAreTheDocumentedApprovedSet() throws {
        #expect(HistoryExport.requestFields.map(\.name) == Self.requestFields)
        #expect(HistoryExport.toolCallFields.map(\.name) == Self.toolCallFields)
        #expect(HistoryExport.csvColumns == ["kind"] + Self.requestFields + Self.toolCallFields.filter { !Self.sharedFields.contains($0) })
        #expect((HistoryExport.requestFields + HistoryExport.toolCallFields).allSatisfy { $0.meaning.count > 10 }, "every field documented")
        // The same privacy boundary as the database: a tool's name is the one tool field.
        let forbidden = ["prompt", "message", "response", "reasoning", "preview", "arg", "result", "error", "output", "payload", "json", "raw"]
        #expect(!HistoryExport.csvColumns.contains { column in forbidden.contains { column.contains($0) } })
        #expect(HistoryExport.csvColumns.filter { $0.contains("tool") } == ["tool_name"])
        // The README documents every exported field for CSV readers.
        let readme = try String(contentsOf: Fixtures.directory.appendingPathComponent("../../README.md"), encoding: .utf8)
        #expect(HistoryExport.csvColumns.allSatisfy { readme.contains("`\($0)`") })
    }

    @Test func csvHoldsEveryRecordInEventOrder() throws {
        let (bench, store) = try Self.exportBench()
        defer { bench.remove() }
        let data = try HistoryExport.data(.csv, requests: store.observations(), toolCalls: store.toolCalls())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasSuffix("\r\n"))
        let table = Self.parseCSV(text)
        #expect(table[0] == HistoryExport.csvColumns)
        let rows = table.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(table[0], $0)) }
        #expect(rows.allSatisfy { $0.count == table[0].count })

        #expect(rows.map { $0["kind", default: "∅"] } == ["model_request", "tool_call", "tool_call", "model_request", "tool_call", "tool_call",
                                              "model_request", "tool_call", "model_request"])
        let requests = try store.observations()
        let calls = try store.toolCalls()
        #expect(rows.filter { $0["kind"] == "model_request" }.map { $0["event_id", default: "∅"] } == requests.map(\.eventID))
        #expect(rows.filter { $0["kind"] == "tool_call" }.map { $0["event_id", default: "∅"] } == calls.map(\.eventID))
        #expect(rows.filter { $0["kind"] == "model_request" }.map { $0["context_percentage", default: "∅"] } == ["30.0", "", "40.0", "25.0"])
        #expect(rows.filter { $0["kind"] == "tool_call" }.map { "\($0["tool_name", default: "∅"]) \($0["skill_name", default: "∅"]) \($0["estimated_tokens", default: "∅"])" }
                == ["skill_view writing 900", "terminal  120", "read_file  30", "terminal  0", "skill_view research 2400"])
        #expect(rows.last?["model"] == "model \"q\", with\nbreak", "quoted, quotes doubled, line break kept")
        // A request has no tool fields and a call no context fields: those cells are empty.
        #expect(rows.allSatisfy { row in
            let other = row["kind"] == "tool_call" ? Self.requestFields : Self.toolCallFields
            return other.filter { !Self.sharedFields.contains($0) }.allSatisfy { row[$0] == "" }
        })
        for row in rows {
            #expect(try Self.timestamp.wholeMatch(in: try #require(row["timestamp"])) != nil)
            let measured = try #require(row["context_measured_at"])
            #expect(try measured.isEmpty || Self.timestamp.wholeMatch(in: measured) != nil)
        }
    }

    @Test func jsonDocumentsItsFieldsAndHoldsOnlyThem() throws {
        let (bench, store) = try Self.exportBench()
        defer { bench.remove() }
        let exportedAt = try SnapshotDecoder.parseTimestamp("2026-09-26T09:30:00Z")
        let data = try HistoryExport.data(.json, requests: store.observations(), toolCalls: store.toolCalls(), exportedAt: exportedAt)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(document.keys) == ["format", "exported_at", "timestamps", "fields", "requests", "tool_calls"])
        #expect(document["format"] as? String == "hermes-context.history.v1")
        #expect(document["exported_at"] as? String == "2026-09-26T09:30:00.000Z")
        #expect(document["timestamps"] as? String == "UTC, ISO 8601 with milliseconds")
        let fields = try #require(document["fields"] as? [String: [[String: String]]])
        #expect(fields["requests"]?.map { $0["name", default: "∅"] } == Self.requestFields)
        #expect(fields["tool_calls"]?.map { $0["name", default: "∅"] } == Self.toolCallFields)
        #expect(fields.values.joined().allSatisfy { Set($0.keys) == ["name", "meaning"] })

        let requests = try #require(document["requests"] as? [[String: Any]])
        let calls = try #require(document["tool_calls"] as? [[String: Any]])
        #expect(requests.count == 4 && calls.count == 5)
        #expect(requests.allSatisfy { Set($0.keys) == Set(Self.requestFields) }, "null fields stay present")
        #expect(calls.allSatisfy { Set($0.keys) == Set(Self.toolCallFields) })
        #expect(requests.map { $0["event_id"] as? String } == (try store.observations()).map(\.eventID))
        #expect(requests.map { $0["context_percentage"] as? Double } == [30, nil, 40, 25])
        #expect(requests[1]["context_used"] is NSNull)
        #expect(requests[3]["model"] as? String == "model \"q\", with\nbreak")
        #expect(calls.map { $0["request_event_id"] as? String } == (try store.toolCalls()).map(\.requestEventID))
        #expect(calls.map { $0["duration_ms"] as? Int } == (try store.toolCalls()).map(\.durationMS))
        for record in requests + calls {
            #expect(try Self.timestamp.wholeMatch(in: try #require(record["timestamp"] as? String)) != nil)
        }
        #expect(String(data: data, encoding: .utf8)?.contains("33.299999") == false)
    }

    // MARK: Clear

    /// Clearing empties the history on disk, keeps the cursors so nothing already imported comes back, and never
    /// writes a bridge file.
    @Test func clearEmptiesTheHistoryAndLeavesTheBridgeAlone() throws {
        let bench = try Bench()
        defer { bench.remove() }
        try bench.publish(Fixtures.event(profile: "alpha", sequence: 8, session: "alpha-3"), profile: "alpha")  // 7 never arrives
        let store = try bench.open()
        try store.importEvents(from: bench.location)
        #expect(try store.skippedRecords() == ["alpha": 1])
        let bridge = try bench.bridgeFiles()
        try bench.checkpoint()
        let sentinels = ["alpha-3", "model-a", "research"]
        #expect(sentinels.allSatisfy { (try? Data(contentsOf: bench.database))?.range(of: Data($0.utf8)) != nil },
                "the rows were in the main database file before the clear")

        try store.clearHistory(importingFrom: bench.location)

        #expect(try store.observations().isEmpty)
        #expect(try store.toolCalls().isEmpty)
        #expect(try store.issues().isEmpty)
        #expect(try store.skippedRecords().isEmpty)
        #expect(try store.lineages().isEmpty)
        #expect(Self.line(try store.insights().overall) == "0 0 - - -")
        #expect(try bench.rows("SELECT profile, sequence FROM import_cursors ORDER BY profile") == [["alpha", "8"], ["beta", "2"]])
        #expect(!sentinels.contains(where: bench.databaseContains), "no deleted row left in the database, WAL or shm")
        #expect(try store.importEvents(from: bench.location) == ImportSummary())
        #expect(try bench.open().importEvents(from: bench.location) == ImportSummary(), "a relaunch reads nothing back")
        #expect(try bench.bridgeFiles() == bridge, "every bridge file byte-identical")

        try bench.publish(Fixtures.event(profile: "alpha", sequence: 9, session: "alpha-3"), profile: "alpha")
        #expect(try store.importEvents(from: bench.location) == ImportSummary(imported: 1))
        #expect(try store.observations().map(\.sequence) == [9])
    }

    /// Events published but not imported yet belong to what a clear removes: they never come back afterwards.
    @Test func clearCoversEventsNotImportedYet() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let store = try bench.open()

        try store.clearHistory(importingFrom: bench.location)

        #expect(try store.importEvents(from: bench.location) == ImportSummary())
        #expect(try store.observations().isEmpty)
        #expect(try store.toolCalls().isEmpty)
    }

    /// A history of many pages: the clear leaves no free page and no deleted byte behind, whatever SQLite's
    /// secure-delete default (macOS ships FAST, which zeroes a small table's pages anyway).
    @Test func clearLeavesNoDeletedPageBehind() throws {
        let bench = try Bench(fixture: false)
        defer { bench.remove() }
        let sentinel = "BULK-SENTINEL-4c1d"
        for sequence in 1...400 {
            var event = Fixtures.event(profile: "alpha", sequence: sequence, session: "alpha-1")
            event["model"] = sentinel
            try bench.publish(event, profile: "alpha")
        }
        let store = try bench.open()
        try store.importEvents(from: bench.location)
        try bench.checkpoint()
        #expect(try Data(contentsOf: bench.database).range(of: Data(sentinel.utf8)) != nil)

        try store.clearHistory(importingFrom: bench.location)

        #expect(try bench.rows("PRAGMA freelist_count") == [["0"]])
        #expect(!bench.databaseContains(sentinel))
    }

    /// RFC 4180 rows: quoted cells may hold commas, doubled quotes and line breaks.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch (quoted, scalar) {
            case (true, "\""):
                if pending == "\"" { cell.unicodeScalars.append("\""); pending = scalars.next() } else { quoted = false }
            case (true, _): cell.unicodeScalars.append(scalar)
            case (false, "\""): quoted = true
            case (false, ","): row.append(cell); cell = ""
            case (false, "\r"): break
            case (false, "\n"): row.append(cell); rows.append(row); (row, cell) = ([], "")
            default: cell.unicodeScalars.append(scalar)
            }
        }
        return rows
    }
}

extension Bench {
    /// Every file under the Hermes root, outside the database's own directory, by path.
    func bridgeFiles() throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        return try Dictionary(uniqueKeysWithValues: files
            .filter { try !$0.path.contains("/app/") && $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .map { ($0.path, try Data(contentsOf: $0)) })
    }

    /// Checkpoints the WAL into the main file, as a long-lived history would be.
    func checkpoint() throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(database.path, &db) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// True when `text` is anywhere in the database file, its WAL or its shared memory.
    func databaseContains(_ text: String) -> Bool {
        ["", "-wal", "-shm"].contains { suffix in
            ((try? Data(contentsOf: URL(fileURLWithPath: database.path + suffix))) ?? Data()).range(of: Data(text.utf8)) != nil
        }
    }
}
