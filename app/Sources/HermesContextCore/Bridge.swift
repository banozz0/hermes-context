import Foundation

/// Where participating profiles publish: the default home `<root>/hermes-context/v1/` and every named profile
/// `<root>/profiles/<name>/hermes-context/v1/`, each holding `snapshot.json` and the append-only `events/` tree.
public struct BridgeLocation: Sendable {
    public static let snapshotSuffix = "hermes-context/v1/snapshot.json"
    public static let eventsSuffix = "hermes-context/v1/events"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `HERMES_CONTEXT_HERMES_ROOT` overrides `~/.hermes` for tests and headless checks.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeLocation {
        if let override = environment["HERMES_CONTEXT_HERMES_ROOT"], !override.isEmpty {
            return BridgeLocation(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        return BridgeLocation(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true))
    }

    /// The default home and every named profile home, in a stable order.
    func homes(fileManager: FileManager) -> [URL] {
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: profiles.path)) ?? []
        return [root] + names.sorted().filter { !$0.hasPrefix(".") }.map { profiles.appendingPathComponent($0, isDirectory: true) }
    }

    /// Snapshot files present right now, in a stable order. Profiles without the plugin have none.
    /// An unreadable file is still listed so its read fails visibly instead of the profile vanishing.
    public func discoverSnapshots(fileManager: FileManager = .default) -> [URL] {
        homes(fileManager: fileManager)
            .map { $0.appendingPathComponent(Self.snapshotSuffix) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Each profile's append-only event directory that exists right now, with the profile its events must name.
    public func discoverEventDirectories(fileManager: FileManager = .default) -> [(profile: String, directory: URL)] {
        homes(fileManager: fileManager)
            .map { $0.appendingPathComponent(Self.eventsSuffix, isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map { (Self.profile(of: $0), $0) }
    }

    /// When each profile Hermes runs right now started, keyed by the snapshot file its plugin should publish. Hermes's
    /// own rule: a profile runs when its `gateway_state.json` names a live gateway (`GatewayStatus.running`), or the
    /// root's does and lists it in `served_profiles`. A status file that is missing, unreadable or reshaped runs nothing.
    public func gatewayStarts(fileManager: FileManager = .default) -> [URL: Date] {
        let rootGateway = GatewayStatus.running(in: root)
        let served = rootGateway?.servedProfiles ?? []
        var started: [URL: Date] = [:]
        for home in homes(fileManager: fileManager) {
            let snapshot = home.appendingPathComponent(Self.snapshotSuffix)
            let own = home == root ? rootGateway : GatewayStatus.running(in: home)
            let gateway = own ?? (served.contains(Self.profile(of: snapshot)) ? rootGateway : nil)
            started[snapshot] = gateway?.startedAt
        }
        return started
    }

    /// The profile a bridge path belongs to, as Hermes names it: `profiles/<name>/hermes-context/v1/<entry>`,
    /// else `default` for the root home.
    static func profile(of entry: URL) -> String {
        let home = entry.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return home.deletingLastPathComponent().lastPathComponent == "profiles" ? home.lastPathComponent : "default"
    }

    /// True for a path the watcher should react to: a snapshot, a published event, or a profile appearing or
    /// leaving. FSEvents reports resolved paths (`/private/var/...`), so match on shape, not on the root prefix.
    public static func isRelevant(path: String) -> Bool {
        if path.hasSuffix(".json") {
            let file = URL(fileURLWithPath: path)
            let segment = file.deletingLastPathComponent()
            return path.hasSuffix("/" + snapshotSuffix)
                || (segment.deletingLastPathComponent().path.hasSuffix("/" + eventsSuffix)
                    && EventFile(segment: segment.lastPathComponent, name: file.lastPathComponent) != nil)
        }
        return path.hasSuffix("/hermes-context/v1")
            || path.hasSuffix("/hermes-context")
            || URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent == "profiles"
    }
}

/// One published event file: `<segment>/<12-digit sequence>-<event_id>.json` under a profile's events directory.
/// The observer's layout lives here alone; temporary files and anything else in the tree are not events.
struct EventFile: Equatable {
    let segment: String
    let sequence: Int
    let eventID: String

    var path: String { "\(segment)/\(String(format: "%012ld", sequence))-\(eventID).json" }

    init(segment: String, sequence: Int, eventID: String) {
        self.segment = segment
        self.sequence = sequence
        self.eventID = eventID
    }

    init?(segment: String, name: String) {
        let digits = name.prefix(12)
        guard !segment.isEmpty, segment.allSatisfy(\.isASCIIDigit), digits.count == 12, digits.allSatisfy(\.isASCIIDigit),
              name.dropFirst(12).hasPrefix("-"), name.hasSuffix(".json"), let sequence = Int(digits) else { return nil }
        let eventID = String(name.dropFirst(13).dropLast(5))
        guard SnapshotDecoder.isIdentity(eventID) else { return nil }
        self.init(segment: segment, sequence: sequence, eventID: eventID)
    }

    /// Event files past `cursor` in (sequence, event ID) order, so a second file on the cursor's sequence number is
    /// still ahead of it. Segments only grow, so none before the cursor's is listed.
    static func list(in directory: URL, after cursor: EventFile?, fileManager: FileManager = .default) -> [EventFile] {
        let floor = cursor.flatMap { Int($0.segment) } ?? 0
        let segments = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && Int($0) ?? 0 >= floor }
        return segments.flatMap { segment in
            ((try? fileManager.contentsOfDirectory(atPath: directory.appendingPathComponent(segment).path)) ?? [])
                .compactMap { EventFile(segment: segment, name: $0) }
                .filter { file in cursor.map { (file.sequence, file.eventID) > ($0.sequence, $0.eventID) } ?? true }
        }.sorted { ($0.sequence, $0.eventID) < ($1.sequence, $1.eventID) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// A home's `gateway_state.json`, read-only. The decoder maps these four fields and nothing else: the file also holds
/// the gateway's command line and agent lists, which never enter the app.
struct GatewayStatus: Decodable {
    static let fileName = "gateway_state.json"

    let pid: Int?
    let state: String?
    let servedProfiles: [String]?
    /// The gateway process's creation time on macOS, in centiseconds since the epoch.
    let startTime: Double?

    private enum CodingKeys: String, CodingKey {
        case pid, state = "gateway_state", servedProfiles = "served_profiles", startTime = "start_time"
    }

    var startedAt: Date? { startTime.map { Date(timeIntervalSince1970: $0 / 100) } }

    /// Hermes's recycled-pid guard compares start times exactly; the app allows the 2 seconds of drift Hermes's own
    /// reconciliation allows (`start_time_fingerprints_match`: macOS adjusts its boot time, and rounding can differ).
    static let startDrift: Double = 200

    /// The home's gateway when its file says it serves (`running`, or `degraded` with some platforms parked) and its
    /// pid is live and still the process that wrote the file: Hermes's own guard against a recycled pid. A file with
    /// no start time proves nothing, so it runs nothing.
    static func running(in home: URL) -> GatewayStatus? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(fileName)),
              let status = try? JSONDecoder().decode(GatewayStatus.self, from: data),
              ["running", "degraded"].contains(status.state),
              let recorded = status.startTime, let pid = status.pid.flatMap(pid_t.init(exactly:)), pid > 0 else { return nil }
        guard let live = processStart(pid), abs(live - recorded) <= startDrift else { return nil }
        return status
    }

    /// A live process's creation time as Hermes records it on macOS (psutil's `create_time`, in centiseconds), from
    /// the kernel's process table, which lists every user's processes; `nil` when no process has that pid.
    static func processStart(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return ((Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000) * 100).rounded()
    }
}

/// One read of the whole bridge. A bad profile file is reported, never allowed to blank the others.
public struct BridgeReading: Sendable {
    public struct Entry: Sendable {
        public let file: URL
        public let result: Result<ProfileSnapshot, BridgeFailure>
    }

    public let entries: [Entry]
    /// `BridgeLocation.gatewayStarts` at the time of this read.
    public let gatewayStarts: [URL: Date]

    public var snapshots: [ProfileSnapshot] { entries.compactMap { try? $0.result.get() } }
    public var failures: [BridgeFailure] {
        entries.compactMap { if case .failure(let failure) = $0.result { failure } else { nil } }
    }

    public static func read(_ location: BridgeLocation) -> BridgeReading {
        BridgeReading(entries: location.discoverSnapshots().map { file in
            do {
                return Entry(file: file, result: .success(try SnapshotDecoder.decode(Data(contentsOf: file))))
            } catch {
                return Entry(file: file, result: .failure(BridgeFailure(file: file, reason: BridgeFailure.describe(error))))
            }
        }, gatewayStarts: location.gatewayStarts())
    }
}

public struct BridgeFailure: Error, Equatable, Sendable {
    public let file: URL
    public let reason: String

    /// The profile a file belongs to, from its path alone: `profiles/<name>/…` or the default home.
    public var profile: String { BridgeLocation.profile(of: file) }

    /// One short line: the contract error, or the decoder's own message at its field path.
    static func describe(_ error: Error) -> String {
        let text: String
        switch error {
        case SnapshotError.malformed(let detail): text = "Malformed snapshot: \(detail)"
        case let error as SnapshotError: text = error.description
        case let error as CocoaError where error.code == .fileReadNoPermission: text = "Snapshot is not readable"
        case let error as CocoaError: text = "Cannot read snapshot: \(error.localizedDescription)"
        default: text = String(describing: error)
        }
        return text.count > 200 ? String(text.prefix(199)) + "…" : text
    }
}

/// What a profile is showing when it is not a clean live snapshot.
public struct BridgeDiagnostic: Equatable, Sendable, Identifiable {
    public enum Problem: Equatable, Sendable {
        /// The file failed to read or decode; `retained` means its last good snapshot is still shown.
        case unreadable(reason: String, retained: Bool)
        /// The heartbeat went stale; the last snapshot is shown marked Offline.
        case offline(lastHeartbeat: Date)
        /// Event records the history is missing because they were absent, rejected or unreadable.
        case skippedEvents(count: Int)
        /// The live plugin reports features a Hermes update switched off.
        case degraded([DegradedFeature])
        /// Hermes runs the profile's gateway, yet its snapshot is missing or Offline.
        case notReporting
    }

    public let file: URL
    public let profile: String
    public let problem: Problem
    public var id: String { file.path }

    public func message(now: Date) -> String {
        switch problem {
        case .unreadable(let reason, let retained):
            retained ? "\(reason.hasSuffix(".") ? reason : reason + ".") Showing its last good snapshot." : reason
        case .offline(let heartbeat):
            "Gateway offline, last heartbeat \(LiveSession.elapsed(since: heartbeat, now: now))."
        case .skippedEvents(let count):
            "History skipped \(count) event record\(count == 1 ? "" : "s"): missing, corrupt or unsupported."
        case .degraded(let features):
            "\(Self.lostSentence(features)) Rerun the install line for the latest Hermes Context."
        case .notReporting:
            "Hermes runs \(profile), but Hermes Context gets nothing from it. Rerun the install line."
        }
    }

    /// `A Hermes update switched off session titles and tool history.` A lost `sessions` outranks the rest: with no
    /// sessions to show, the other features are moot.
    private static func lostSentence(_ features: [DegradedFeature]) -> String {
        if features.contains(.sessions) { return "Hermes Context can't see its sessions." }
        var words = features.map(\.userWords)
        let last = words.popLast() ?? ""
        return "A Hermes update switched off \(words.isEmpty ? last : words.joined(separator: ", ") + " and " + last)."
    }

    /// One diagnostic per profile whose history skipped event records, pointing at its events directory.
    public static func skippedEvents(_ counts: [String: Int], in location: BridgeLocation) -> [BridgeDiagnostic] {
        location.discoverEventDirectories().compactMap { source in
            counts[source.profile].map { BridgeDiagnostic(file: source.directory, profile: source.profile, problem: .skippedEvents(count: $0)) }
        }
    }
}

/// The app's view of the bridge across reads. A profile whose file turns corrupt or unsupported keeps
/// its last good snapshot (still aging to Offline by heartbeat) and gains a diagnostic; healthy
/// profiles are never touched. A file that disappears takes its profile with it.
public struct BridgeState: Sendable {
    /// A gateway's first minute is normal startup: its plugin has not beaten yet.
    static let startupGrace: TimeInterval = 60

    private var lastGood: [URL: ProfileSnapshot] = [:]
    private var gatewayStarts: [URL: Date] = [:]
    public private(set) var snapshots: [ProfileSnapshot] = []
    public private(set) var failures: [BridgeFailure] = []

    public init() {}

    public mutating func apply(_ reading: BridgeReading) {
        var kept: [URL: ProfileSnapshot] = [:]
        gatewayStarts = reading.gatewayStarts
        snapshots = []
        failures = []
        for entry in reading.entries {
            switch entry.result {
            case .success(let snapshot):
                kept[entry.file] = snapshot
            case .failure(let failure):
                failures.append(failure)
                kept[entry.file] = lastGood[entry.file]
            }
            if let snapshot = kept[entry.file] { snapshots.append(snapshot) }
        }
        lastGood = kept
    }

    /// Read failures first, then running gateways whose plugin is silent, then offline gateways, then live plugins
    /// that lost features, in discovery order. A file gets one line: a silent plugin's replaces its offline one, and
    /// an offline profile's degraded report is from a gateway that is gone.
    public func diagnostics(now: Date) -> [BridgeDiagnostic] {
        let failed = failures.map { failure in
            BridgeDiagnostic(file: failure.file, profile: failure.profile,
                             problem: .unreadable(reason: failure.reason, retained: lastGood[failure.file] != nil))
        }
        let failedFiles = Set(failures.map(\.file))
        let silentFiles = Set(gatewayStarts.filter { file, started in
            let quiet = lastGood[file]?.isOffline(at: now) ?? true  // no snapshot, or one gone Offline
            return !failedFiles.contains(file) && quiet && now.timeIntervalSince(started) >= Self.startupGrace
        }.keys)
        let silent = silentFiles.sorted { $0.path < $1.path }.map {
            BridgeDiagnostic(file: $0, profile: BridgeLocation.profile(of: $0), problem: .notReporting)
        }
        let explained = failedFiles.union(silentFiles)
        var offline: [BridgeDiagnostic] = []
        var degraded: [BridgeDiagnostic] = []
        for (file, snapshot) in lastGood.sorted(by: { $0.key.path < $1.key.path }) where !explained.contains(file) {
            if snapshot.isOffline(at: now) {
                offline.append(BridgeDiagnostic(file: file, profile: snapshot.profile, problem: .offline(lastHeartbeat: snapshot.heartbeatAt)))
            } else if !snapshot.degraded.isEmpty {
                degraded.append(BridgeDiagnostic(file: file, profile: snapshot.profile, problem: .degraded(snapshot.degraded)))
            }
        }
        return failed + silent + offline + degraded
    }
}
