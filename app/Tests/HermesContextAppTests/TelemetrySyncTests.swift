import Foundation
import Testing
@testable import HermesContext
@testable import HermesContextCore

@Suite struct TelemetrySyncTests {
    /// A fixture root must never write Sven's real history: overriding the Hermes root, or running headless,
    /// needs an explicit database.
    @Test func realHistoryOnlyForTheRealBridge() {
        let explicit = TelemetrySync.databaseURL(["HERMES_CONTEXT_DATABASE": "/tmp/x.sqlite", "HERMES_CONTEXT_HEADLESS": "1"])
        #expect(explicit?.path == "/tmp/x.sqlite")
        #expect(TelemetrySync.databaseURL(["HERMES_CONTEXT_HERMES_ROOT": "/tmp/root"]) == nil)
        #expect(TelemetrySync.databaseURL(["HERMES_CONTEXT_HEADLESS": "1"]) == nil)
        #expect(TelemetrySync.databaseURL([:]) == TelemetryStore.defaultURL)
        #expect(TelemetryStore.defaultURL.path.hasSuffix("Application Support/dev.banozz0.hermes-context/telemetry.sqlite"))
    }

    @Test func aBurstQueuesOneImport() async throws {
        let root = try Self.root(events: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = try TelemetrySync(database: root.appendingPathComponent("app/telemetry.sqlite"), location: BridgeLocation(root: root))

        #expect(sync.queue())
        #expect(!sync.queue())
        _ = await sync.sync()
        #expect(sync.queue(), "a change after the import started gets a follow-up")
    }

    /// The popover and Settings show what the history skipped, through the real reload path.
    @MainActor @Test func skippedRecordsReachTheDiagnostics() async throws {
        let root = try Self.root(events: [1, 3])  // 2 never arrives
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "dev.banozz0.hermes-context.tests.app.skippedRecords"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let location = BridgeLocation(root: root)
        let store = LiveStore(location: location, settings: AppSettings(defaults: try #require(UserDefaults(suiteName: suite))), check: nil,
                              history: .success(try TelemetrySync(database: root.appendingPathComponent("app/telemetry.sqlite"), location: location)))

        store.reload()
        for _ in 0..<100 where store.diagnostics.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(store.diagnostics.map(\.profile) == ["alpha"])
        #expect(store.diagnostics.map { $0.message(now: Date()) } == ["History skipped 1 event record: missing, corrupt or unsupported."])
        #expect(store.diagnostics.first?.file.path.hasSuffix("profiles/alpha/hermes-context/v1/events") == true)
    }

    /// A temporary Hermes root whose alpha profile published one valid event per sequence number.
    private static func root(events sequences: [Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-sync-\(UUID().uuidString)", isDirectory: true)
        let segment = root.appendingPathComponent("profiles/alpha/\(BridgeLocation.eventsSuffix)/000001", isDirectory: true)
        try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
        for sequence in sequences {
            let id = "hc1:" + String(repeating: String(sequence), count: 64)
            let event: [String: Any] = [
                "contract_version": "hermes-context.v1", "kind": "model_request", "event_id": id, "sequence": sequence,
                "routing_id": "hc1:" + String(repeating: "f", count: 64), "lineage_root_id": "alpha-1",
                "previous_session_id": NSNull(), "session_id": "alpha-1", "timestamp": "2026-09-24T10:00:00Z", "profile": "alpha",
                "model": NSNull(), "provider": NSNull(), "state": "working",
                "context": ["used": NSNull(), "maximum": NSNull(), "percentage": NSNull(), "source": NSNull(), "measured_at": NSNull()],
            ]
            let file = EventFile(segment: "000001", sequence: sequence, eventID: id)
            try JSONSerialization.data(withJSONObject: event).write(to: segment.deletingLastPathComponent().appendingPathComponent(file.path))
        }
        return root
    }
}
