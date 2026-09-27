import Foundation
import HermesContextCore
import os

/// Imports newly published bridge events into the app's SQLite history, off the main thread and one import
/// at a time. A failed import leaves its batch uncommitted; the next bridge change or tick retries it.
actor TelemetrySync {
    private static let log = Logger(subsystem: "dev.banozz0.hermes-context", category: "telemetry")
    private let store: TelemetryStore
    private let location: BridgeLocation
    /// Set while an import is queued, so a burst of bridge changes queues one import rather than one each.
    private nonisolated let queued = OSAllocatedUnfairLock(initialState: false)
    /// The last statistics, rebuilt only when an import stored something or the history was cleared. A failed import or
    /// clear may have committed part of its work, so it drops them.
    private var report: InsightsReport?

    /// What the app shows from the history after an import: skipped-record diagnostics and the Insights statistics.
    struct Update: Sendable {
        let diagnostics: [BridgeDiagnostic]
        let report: InsightsReport
    }

    init(database: URL, location: BridgeLocation) throws {
        self.init(store: try TelemetryStore(url: database), location: location)
    }

    init(store: sending TelemetryStore, location: BridgeLocation) {
        self.store = store
        self.location = location
    }

    /// `HERMES_CONTEXT_DATABASE`, else the real history, which only the real bridge may write: a run that
    /// overrides the Hermes root, or runs headless, keeps no history unless it names a database.
    static func databaseURL(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment["HERMES_CONTEXT_DATABASE"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let fixtureRoot = !(environment["HERMES_CONTEXT_HERMES_ROOT"] ?? "").isEmpty
        return fixtureRoot || HeadlessCheck.fromEnvironment(environment) != nil ? nil : TelemetryStore.defaultURL
    }

    /// This run's history: `nil` when it keeps none, else the opened database or why it failed to open. The live list
    /// works either way.
    static func fromEnvironment(location: BridgeLocation, _ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Result<TelemetrySync, any Error>? {
        guard let database = databaseURL(environment) else { return nil }
        let result = Result { try TelemetrySync(database: database, location: location) }
        if case .failure(let error) = result {
            log.error("Telemetry history unavailable at \(database.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return result
    }

    /// True when this call queued an import, false when one was already waiting. A running import does not
    /// count as waiting, so a change during it still gets a follow-up.
    nonisolated func queue() -> Bool {
        queued.withLock { wasQueued in
            defer { wasQueued = true }
            return !wasQueued
        }
    }

    /// Imports what was published since the last import. A database failure changes nothing and is returned.
    func sync() -> Result<Update, any Error> {
        queued.withLock { $0 = false }
        do {
            let summary = try store.importEvents(from: location)
            if summary.issues > 0 {
                Self.log.warning("Telemetry import stepped over \(summary.issues) record(s); see ingest_issues")
            }
            return .success(try update(rebuild: summary.imported > 0))
        } catch {
            Self.log.error("Telemetry import failed: \(String(describing: error), privacy: .public)")
            report = nil
            return .failure(error)
        }
    }

    func clear() -> Result<Update, any Error> {
        do {
            try store.clearHistory(importingFrom: location)
            return .success(try update(rebuild: true))
        } catch {
            Self.log.error("Clearing history failed: \(String(describing: error), privacy: .public)")
            report = nil
            return .failure(error)
        }
    }

    /// Writes every stored request and tool call, as imported so far, to `url`.
    func export(_ format: HistoryExport.Format, to url: URL) throws {
        try HistoryExport.data(format, requests: store.observations(), toolCalls: store.toolCalls()).write(to: url, options: .atomic)
    }

    private func update(rebuild: Bool) throws -> Update {
        let report = try (rebuild ? nil : self.report) ?? store.insights()
        self.report = report
        return Update(diagnostics: BridgeDiagnostic.skippedEvents(try store.skippedRecords(), in: location), report: report)
    }
}

/// What the Insights window shows: the history's statistics, or why there are none.
enum HistoryState: Equatable, Sendable {
    /// This run keeps no history: a fixture root or a headless run without `HERMES_CONTEXT_DATABASE`.
    case off
    case loading
    /// The database failed to open or to import; the live list is unaffected.
    case unavailable(String)
    case ready(InsightsReport)

    var report: InsightsReport? {
        if case .ready(let report) = self { report } else { nil }
    }
}
