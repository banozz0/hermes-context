import AppKit
import os
import SQLite3
import SwiftUI
import Testing
@testable import HermesContext
@testable import HermesContextCore

/// Native smoke for Insights: the real window and view over a fixture root whose replay events the real importer
/// stores in a throwaway database, read back with Vision.
@MainActor
@Suite(.serialized) struct InsightsSmokeTests {
    typealias UI = DetailViewSmokeTests
    static let size = NSSize(width: 660, height: 560)

    /// alpha and beta snapshots plus, unless `events` is false, the replay fixture's events where the observer puts them.
    static func root(events publishes: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-insights-\(UUID().uuidString)", isDirectory: true)
        for (profile, fixture) in ["alpha": "alpha.snapshot.json", "beta": "beta.snapshot.json"] {
            let directory = root.appendingPathComponent("profiles/\(profile)/hermes-context/v1", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contentsOf: UI.fixtures.appendingPathComponent(fixture)).write(to: directory.appendingPathComponent("snapshot.json"))
        }
        if publishes { try publishReplay(root) }
        return root
    }

    static func publishReplay(_ root: URL) throws {
        for (profile, events) in try replay() {
            for event in events { try publish(event, profile: profile, root: root) }
        }
    }

    /// `events/replay.json`: each profile's events, in order.
    static func replay() throws -> [String: [[String: Any]]] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: UI.fixtures.appendingPathComponent("events/replay.json")))
            as? [String: [[String: Any]]])
    }

    static func publish(_ event: [String: Any], profile: String, root: URL) throws {
        let file = EventFile(segment: "000001", sequence: event["sequence"] as! Int, eventID: event["event_id"] as! String)
        let events = root.appendingPathComponent("profiles/\(profile)/\(BridgeLocation.eventsSuffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: events.appendingPathComponent(file.segment), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: event).write(to: events.appendingPathComponent(file.path))
    }

    static func database(_ root: URL) -> URL { root.appendingPathComponent("app/telemetry.sqlite") }

    /// A live store importing into the root's throwaway database, once its first import has landed.
    static func store(_ root: URL, _ settings: AppSettings) async throws -> LiveStore {
        let location = BridgeLocation(root: root)
        let store = LiveStore(location: location, settings: settings, check: nil,
                              history: .success(try TelemetrySync(database: database(root), location: location)), clock: { UI.now })
        store.reload()
        try await wait { store.history.report != nil }
        return store
    }

    /// Suspends, so the store can apply each import on the main actor, until `condition` holds or 15 seconds pass.
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// Sends ⌘`key` to the host's window, ordered in transparent and blind to the mouse like `UI.click`.
    static func pressCommand(_ key: String, in host: NSView) throws {
        let window = try #require(host.window)
        try UI.orderedIn(window) {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            ))
            _ = window.performKeyEquivalent(with: event)
        }
    }

    /// Every file under the root except the database's, by path.
    static func bridgeFiles(_ root: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try Dictionary(uniqueKeysWithValues: files.filter { !$0.hasDirectoryPath && !$0.path.contains("/app/") }
            .map { ($0.path, try Data(contentsOf: $0)) })
    }

    static func joined(_ texts: [String]) -> String { UI.fold(texts.joined(separator: "\n")) }

    @Test func popoverOpensInsightsInItsOwnWindow() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withSettings { settings, _ in
            let store = try await Self.store(root, settings)
            var activations = 0
            let insights = InsightsWindow(store: store, activate: { activations += 1 })
            // Transparent and blind to the mouse, so nothing reaches the user's screen.
            insights.window.alphaValue = 0
            insights.window.ignoresMouseEvents = true
            defer { insights.window.orderOut(nil) }
            let popover = UI.host(PopoverView(store: store, launchAtLogin: LaunchAtLogin(item: FakeLoginItem(), settings: settings),
                                              onInsights: insights.show))

            #expect(!insights.window.isVisible, "never shown until asked")
            try Self.pressCommand("i", in: popover)
            #expect(insights.window.isVisible && activations == 1)
            #expect(insights.window !== popover.window)
            #expect(insights.window.title == "Insights")
            #expect(insights.window.styleMask.isSuperset(of: [.titled, .closable, .resizable]))
            #expect(insights.window.contentViewController is NSHostingController<InsightsView>)
            let window = insights.window
            insights.show()
            #expect(insights.window === window, "one Insights window, reused")

            // alpha thread-1 ran alpha-1 at 30% until /new replaced it with alpha-3, current at 40%; beta measured nothing.
            let report = try #require(store.history.report)
            let tables = InsightsReportView(report: report, lanes: store.allLanes.all)
            #expect(tables.profileRows.map { [$0.label] + $0.cells } == [
                ["All profiles", "3", "2", "35%", "35%", "40%"], ["Alpha", "2", "2", "35%", "35%", "40%"], ["Beta", "1", "0", "—", "—", "—"],
            ])
            #expect(report.lanes.map(tables.name) == ["First thread", "First thread"])
            #expect(report.lanes.map { lane in lane.generations.map { tables.status(lane, $0) } } == [["Ended", "Current"], ["Current"]])
            #expect(report.lanes.map { tables.generationRows($0).map(\.cells) } == [
                [["1", "1", "30%", "30%", "30%"], ["1", "1", "40%", "40%", "40%"]], [["1", "0", "—", "—", "—"]],
            ])

            // Vision reads labels and percentages reliably, and a lone digit or dash not at all.
            let texts = try UI.texts(InsightsView(store: store), size: Self.size)
            let joined = Self.joined(texts)
            for text in ["Context usage", "Each model request counts once; statistics are not time-weighted.", "By profile", "By session",
                         "All profiles", "Alpha", "Beta", "35%", "30%", "40%", "First thread · Alpha · 2 generations", "1 generation",
                         "Ended, from", "Current, from", "3 model requests · 5 tool calls", "Export CSV…", "Export JSON…", "Clear History…"] {
                #expect(joined.contains(UI.fold(text)), "missing \(text) in \(texts)")
            }
        }
    }

    @Test func settingsLeadToInsights() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, _ in
            var opened = 0
            let host = UI.host(SettingsView(settings: settings, launchAtLogin: LaunchAtLogin(item: FakeLoginItem(), settings: settings),
                                            bridgeRoot: root, diagnostics: [], now: UI.now, onBack: {}, onInsights: { opened += 1 }))
            let clicked = try UI.click("Export or Clear in Insights…", in: host)
            #expect(clicked && opened == 1)
        }
    }

    /// Clear asks first; Cancel changes nothing; the confirmed clear empties the database and leaves every bridge file.
    @Test func clearAsksFirstAndTouchesOnlyTheHistory() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withSettings { settings, _ in
            let store = try await Self.store(root, settings)
            let bridge = try Self.bridgeFiles(root)
            let host = UI.host(InsightsView(store: store), size: Self.size)
            let database = Self.database(root)
            func stored() throws -> [Int] {
                let history = try TelemetryStore(url: database)
                return [try history.observations().count, try history.toolCalls().count]
            }

            #expect(try UI.click("Clear History…", in: host))
            let asking = try UI.read(host)
            #expect(Self.joined(asking).contains(UI.fold("Clear all history?")), "\(asking)")
            #expect(Self.joined(asking).contains(UI.fold("This deletes 3 model requests, 5 tool calls and anything published since from this Mac.")), "\(asking)")
            #expect(asking.contains("Clear All History") && asking.contains("Cancel"))
            #expect(try stored() == [3, 5], "asking deletes nothing")

            #expect(try UI.click("Cancel", in: host))
            #expect(!Self.joined(try UI.read(host)).contains(UI.fold("Clear all history?")))
            #expect(try stored() == [3, 5])

            #expect(try UI.click("Clear History…", in: host))
            #expect(try UI.click("Clear All History", in: host))
            try await Self.wait { store.history.report?.overall.requests == 0 }
            #expect(try stored() == [0, 0])
            #expect(store.history.report?.toolCalls == 0)
            #expect(try Self.bridgeFiles(root) == bridge, "snapshots and event files byte-identical")
            let cleared = try UI.read(host)
            #expect(Self.joined(cleared).contains(UI.fold("No model requests recorded yet")), "\(cleared)")
            #expect(cleared.contains("History cleared."), "\(cleared)")

            // The live list never depended on the history.
            #expect(store.allLanes.all.count == 3)
        }
    }

    @Test func exportWritesTheImportedHistory() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withSettings { settings, _ in
            let store = try await Self.store(root, settings)
            let csv = root.appendingPathComponent("out/history.csv")
            let json = root.appendingPathComponent("out/history.json")
            try FileManager.default.createDirectory(at: csv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await store.exportHistory(.csv, to: csv)
            try await store.exportHistory(.json, to: json)

            let lines = try String(contentsOf: csv, encoding: .utf8).components(separatedBy: "\r\n")
            #expect(lines.first == HistoryExport.csvColumns.joined(separator: ","))
            #expect(lines.count == 10, "header, 3 requests and 5 tool calls, final line break")
            let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
            let counts = [document["requests"], document["tool_calls"]].map { ($0 as? [Any])?.count }
            #expect(counts == [3, 5])
        }
    }

    /// Opening fails when the database path runs through a regular file: Insights says so instead of staying empty.
    @Test func unopenableHistoryShowsUnavailable() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("app"))
        let location = BridgeLocation(root: root)
        let history = TelemetrySync.fromEnvironment(location: location, ["HERMES_CONTEXT_DATABASE": Self.database(root).path])
        #expect(TelemetrySync.fromEnvironment(location: location, ["HERMES_CONTEXT_HERMES_ROOT": root.path]) == nil, "a fixture root keeps none")
        try withSettings { settings, _ in
            let store = LiveStore(location: location, settings: settings, check: nil, history: history, clock: { UI.now })
            guard case .unavailable = store.history else {
                Issue.record("expected unavailable, got \(store.history)")
                return
            }
            store.reload()
            let texts = try UI.texts(InsightsView(store: store), size: Self.size)
            #expect(Self.joined(texts).contains(UI.fold("History unavailable")), "\(texts)")
            #expect(Self.joined(texts).contains(UI.fold("The live session list is unaffected.")), "\(texts)")
            #expect(store.allLanes.all.count == 3, "the live list still reads the bridge")
        }
    }

    /// An import that fails after committing some batches drops the cached statistics: the next sync shows what the
    /// database holds even when it imports nothing new.
    @Test func aPartlyCommittedFailureDropsTheCachedStatistics() async throws {
        let root = try Self.root(events: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = OSAllocatedUnfairLock(initialState: false)
        let sync = TelemetrySync(store: try Self.store(failingBetaWhile: failing, at: Self.database(root)), location: BridgeLocation(root: root))
        #expect(try await sync.sync().get().report.overall.requests == 0)

        // alpha's batch commits two requests, then beta's first record fails the import.
        try Self.publishReplay(root)
        failing.withLock { $0 = true }
        guard case .failure = await sync.sync() else {
            Issue.record("expected the import to fail")
            return
        }
        // Nothing new to import next time: beta's events are gone and alpha's are behind its cursor.
        failing.withLock { $0 = false }
        try FileManager.default.removeItem(at: root.appendingPathComponent("profiles/beta/\(BridgeLocation.eventsSuffix)"))
        let after = try await sync.sync().get().report
        #expect(after.overall.requests == 2, "the committed alpha batch, not the report cached before it")
        #expect(after.profiles.map(\.profile) == ["alpha"])
    }

    /// A store whose import fails at beta's first request while `failing` holds. Nonisolated, so the store can be sent to
    /// the actor that owns it.
    nonisolated static func store(failingBetaWhile failing: OSAllocatedUnfairLock<Bool>, at url: URL) throws -> TelemetryStore {
        let store = try TelemetryStore(url: url)
        store.interruption = { record in
            struct Crash: Error {}
            if case .request(let event) = record, event.profile == "beta", failing.withLock({ $0 }) { throw Crash() }
        }
        return store
    }

    /// Another connection holds the write lock past the busy timeout, so an import fails: Insights shows history
    /// unavailable, then the next import after the lock is released restores it.
    @Test func failedImportShowsUnavailableUntilTheNextSucceeds() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withSettings { settings, _ in
            let store = try await Self.store(root, settings)
            var lock: OpaquePointer?
            #expect(sqlite3_open(Self.database(root).path, &lock) == SQLITE_OK)
            #expect(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            var late = try #require(try Self.replay()["alpha"]?.first)
            late["sequence"] = 7
            late["event_id"] = "hc1:" + String(repeating: "7", count: 64)
            try Self.publish(late, profile: "alpha", root: root)

            store.reload()
            try await Self.wait { if case .unavailable = store.history { true } else { false } }
            guard case .unavailable(let reason) = store.history else {
                Issue.record("expected unavailable, got \(store.history)")
                sqlite3_close(lock)
                return
            }
            #expect(reason.contains("locked"), "\(reason)")
            #expect(Self.joined(try UI.texts(InsightsView(store: store), size: Self.size)).contains(UI.fold("History unavailable")))

            sqlite3_exec(lock, "ROLLBACK", nil, nil, nil)
            sqlite3_close(lock)
            store.reload()
            try await Self.wait { store.history.report?.overall.requests == 4 }
            #expect(store.history.report?.overall.requests == 4)
        }
    }
}
