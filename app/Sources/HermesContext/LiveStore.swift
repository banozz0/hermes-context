import AppKit
import Foundation
import HermesContextCore
import Observation

/// Owns the bridge reading for the running app: FSEvents for changes, a slow tick for aging rows and
/// for noticing a heartbeat that stopped (a dead gateway writes nothing, so no file event arrives).
@MainActor
@Observable
final class LiveStore {
    private(set) var bridge = BridgeState()
    private(set) var now = Date()
    var query = ""
    /// The routing ID whose details are open, if any.
    var selection: String?

    let location: BridgeLocation
    let settings: AppSettings
    @ObservationIgnored private var watcher: BridgeWatcher?
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private let check: HeadlessCheck?
    @ObservationIgnored private let telemetry: TelemetrySync?
    /// The wall clock; tests pin it so fixture ages never drift with the date.
    @ObservationIgnored private let clock: () -> Date

    /// `history` is this run's database, why it failed to open, or `nil` when the run keeps no history.
    init(location: BridgeLocation, settings: AppSettings, check: HeadlessCheck?, history source: Result<TelemetrySync, any Error>? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.location = location
        self.settings = settings
        self.check = check
        switch source {
        case nil: (telemetry, history) = (nil, .off)
        case .success(let sync): (telemetry, history) = (sync, .loading)
        case .failure(let error): (telemetry, history) = (nil, .unavailable(error.localizedDescription))
        }
        self.clock = clock
    }

    var list: SessionList { SessionList(snapshots: bridge.snapshots, query: query, now: now, hideAfter: settings.hideAfter) }
    /// Every lane, ignoring the search box: the menu icon, warnings and details never depend on a query.
    var allLanes: SessionList { SessionList(snapshots: bridge.snapshots, now: now, hideAfter: settings.hideAfter) }
    var status: MenuStatus { MenuStatus(list: allLanes, threshold: settings.threshold) }
    /// Records the history skipped, per profile, as of the last import.
    private(set) var historyDiagnostics: [BridgeDiagnostic] = []
    /// What Insights shows, as of the last import.
    private(set) var history: HistoryState
    var diagnostics: [BridgeDiagnostic] { bridge.diagnostics(now: now) + historyDiagnostics }

    /// The open lane's details, from the unsearched list so a search cannot strand an open pane.
    var details: SessionDetails? {
        let lanes = allLanes
        guard let selection, let session = lanes.current.first(where: { $0.id == selection }) else { return nil }
        return SessionDetails(session: session, isOffline: lanes.isOffline(session), now: now)
    }

    func start() {
        reload()
        let watcher = BridgeWatcher(location: location) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
        // Rows hide with age and no file change, and a missed event must not freeze the list.
        tick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        importHistory()
        bridge.apply(BridgeReading.read(location))
        now = clock()
        // A lane that left or hid must not reopen its pane by surprise if it ever returns.
        if let selection, !allLanes.current.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        record()
    }

    /// Every bridge change and tick also asks for an import of newly published events; a burst queues one.
    private func importHistory() {
        guard let telemetry, telemetry.queue() else { return }
        Task { apply(await telemetry.sync()) }
    }

    /// Clears the history. Insights calls this only after its explicit confirmation.
    func clearHistory() async {
        guard let telemetry else { return }
        apply(await telemetry.clear())
    }

    func exportHistory(_ format: HistoryExport.Format, to url: URL) async throws {
        guard let telemetry else { throw CocoaError(.featureUnsupported) }
        try await telemetry.export(format, to: url)
    }

    /// A failed import or clear marks the history unavailable until the next one succeeds; the list is unaffected.
    private func apply(_ result: Result<TelemetrySync.Update, any Error>) {
        let (state, skipped) = switch result {
        case .success(let update): (HistoryState.ready(update.report), update.diagnostics)
        case .failure(let error): (HistoryState.unavailable(error.localizedDescription), historyDiagnostics)
        }
        guard state != history || skipped != historyDiagnostics else { return }
        (history, historyDiagnostics) = (state, skipped)
        record()
    }

    private func record() {
        check?.record(allLanes, diagnostics: diagnostics, status: status, settings: settings, history: history, now: now)
    }

    /// The Discord app when one claims `discord:`, else the browser.
    func openDiscord(_ destination: DiscordDestination) {
        let workspace = NSWorkspace.shared
        workspace.open(workspace.urlForApplication(toOpen: destination.appURL) == nil ? destination.webURL : destination.appURL)
    }
}

/// `HERMES_CONTEXT_HEADLESS=1` runs with no menu-bar item so agents can launch the real app without
/// drawing on the user's screen. `HERMES_CONTEXT_CHECK_OUTPUT` receives the merged list after every reload;
/// `HERMES_CONTEXT_CHECK_SECONDS` quits the app through `NSApp.terminate` after that long;
/// `HERMES_CONTEXT_DEFAULTS_SUITE` reads settings from a throwaway defaults domain instead of the app's own.
struct HeadlessCheck {
    let output: URL?
    let seconds: TimeInterval?
    let defaultsSuite: String?

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> HeadlessCheck? {
        guard environment["HERMES_CONTEXT_HEADLESS"] == "1" else { return nil }
        return HeadlessCheck(
            output: environment["HERMES_CONTEXT_CHECK_OUTPUT"].map { URL(fileURLWithPath: $0) },
            seconds: environment["HERMES_CONTEXT_CHECK_SECONDS"].flatMap(TimeInterval.init),
            defaultsSuite: environment["HERMES_CONTEXT_DEFAULTS_SUITE"]
        )
    }

    @MainActor
    func scheduleQuit() {
        guard let seconds else { return }
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Each row carries the exact details pane and Discord link the popover would show for it; `menu` is
    /// what the menu-bar icon shows, `settings` what the app read from its defaults and `history` what Insights shows.
    @MainActor
    func record(_ list: SessionList, diagnostics: [BridgeDiagnostic], status: MenuStatus, settings: AppSettings,
                history: HistoryState, now: Date) {
        guard let output else { return }
        func row(_ session: LiveSession) -> [String: Any] {
            let details = SessionDetails(session: session, isOffline: list.isOffline(session), now: now)
            return [
                "id": session.id, "profile": session.profileLabel, "name": session.displayName,
                "state": session.state.rawValue, "session": session.sessionID, "channel": session.route.channelLabel ?? NSNull(),
                "context": session.context.percentText ?? NSNull(), "offline": details.isOffline,
                "details": Dictionary(uniqueKeysWithValues: (details.fields + details.diagnostics).map { ($0.label, $0.value) }),
                "discord": details.discord?.webURL.absoluteString ?? NSNull(),
            ]
        }
        let body: [String: Any] = [
            "current": list.current.map(row),
            "hidden": list.hidden.map(row),
            "diagnostics": diagnostics.map { ["file": $0.file.path, "profile": $0.profile, "message": $0.message(now: now)] },
            "menu": ["title": status.title, "symbol": status.symbol, "working": status.workingCount, "warnings": status.warnings.map(\.id)],
            "settings": [
                "view_mode": settings.viewMode.rawValue, "threshold": settings.threshold,
                "hide_after_hours": settings.hideAfterHours,
                "launch_at_login_choice": settings.launchAtLoginChoice.map { $0 as Any } ?? NSNull(),
            ],
            "history": Self.history(history),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: output, options: .atomic)
    }

    /// The Insights statistics as numbers: `{"state": "ready", "overall": …, "profiles": …, "lanes": …}`.
    private static func history(_ state: HistoryState) -> [String: Any] {
        func statistics(_ value: ContextStatistics) -> [String: Any] {
            ["requests": value.requests, "measured": value.measured, "mean": value.mean ?? NSNull(),
             "median": value.median ?? NSNull(), "peak": value.peak ?? NSNull()]
        }
        switch state {
        case .off: return ["state": "off"]
        case .loading: return ["state": "loading"]
        case .unavailable(let reason): return ["state": "unavailable", "reason": reason]
        case .ready(let report):
            return [
                "state": "ready", "tool_calls": report.toolCalls, "overall": statistics(report.overall),
                "profiles": Dictionary(uniqueKeysWithValues: report.profiles.map { ($0.profile, statistics($0.statistics)) }),
                "lanes": report.lanes.map { lane in
                    ["routing_id": lane.routingID, "profile": lane.profile, "generations": lane.generations.map {
                        statistics($0.statistics).merging(["session": $0.generation.sessionID]) { $1 }
                    }] as [String: Any]
                },
            ]
        }
    }
}
