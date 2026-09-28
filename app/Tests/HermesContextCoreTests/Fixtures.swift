import CryptoKit
import Foundation
@testable import HermesContextCore

/// The shared v1 bridge fixtures at the repo root, written by the real Python observer.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/v1", isDirectory: true)

    /// alpha after /new rotated thread-1 (alpha-1 → alpha-3), plus thread-2 working.
    static let alpha = "alpha.snapshot.json"
    /// beta in the same Discord thread as alpha's thread-1.
    static let beta = "beta.snapshot.json"
    /// alpha before that /new: thread-1 still on alpha-1.
    static let alphaBeforeReset = "before-reset/alpha.snapshot.json"
    /// gamma: needs attention, working with context, fresh idle, unthreaded idle for over a day.
    static let gamma = "list/gamma.snapshot.json"

    /// Reference clock one minute after the last fixture event.
    static let now = try! SnapshotDecoder.parseTimestamp("2026-09-24T10:05:00.000Z")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func snapshot(_ name: String) throws -> ProfileSnapshot {
        try SnapshotDecoder.decode(data(name))
    }

    /// A fixture with `edit` applied to its JSON object, for off-fixture and malformed cases.
    static func mutate(_ name: String, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// A fixture whose gateway beat at `now`, so its lanes read live rather than Offline; `also` edits it further.
    static func live(_ name: String, also: (inout [String: Any]) -> Void = { _ in }) throws -> ProfileSnapshot {
        try SnapshotDecoder.decode(beating(name, at: now, also: also))
    }

    /// A fixture whose gateway last beat at `heartbeat`; `also` edits it further.
    static func beating(_ name: String, at heartbeat: Date, also: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        try mutate(name) { object in
            var gateway = object["gateway"] as! [String: Any]
            gateway["heartbeat_at"] = heartbeat.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
            object["gateway"] = gateway
            also(&object)
        }
    }

    /// A throwaway Hermes root laid out like `~/.hermes`, with snapshots under `profiles/<name>/`.
    static func hermesRoot(_ profiles: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-\(UUID().uuidString)", isDirectory: true)
        for (profile, fixture) in profiles {
            try install(fixture, profile: profile, root: root)
        }
        return root
    }

    /// Writes a fixture the way the observer does: temporary file, then atomic rename over the snapshot.
    static func install(_ fixture: String, profile: String, root: URL) throws {
        try write(data(fixture), profile: profile, root: root)
    }

    /// `events/replay.json`: alpha→beta→alpha completed requests with a `/new`, written by the real observer.
    static func replayEvents() throws -> [String: [[String: Any]]] {
        try JSONSerialization.jsonObject(with: data("events/replay.json")) as! [String: [[String: Any]]]
    }

    /// One event file where the observer puts it: `events/<segment>/<sequence>-<event_id>.json` under the
    /// profile's home (`nil` is the default home). `body` replaces the encoded event, for corrupt files.
    static func publish(_ event: [String: Any], profile: String?, root: URL, segment: String = "000001", body: Data? = nil) throws {
        let directory = home(profile, root: root).appendingPathComponent("\(BridgeLocation.eventsSuffix)/\(segment)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = EventFile(segment: segment, sequence: event["sequence"] as! Int, eventID: event["event_id"] as! String)
        try (body ?? JSONSerialization.data(withJSONObject: event, options: .sortedKeys))
            .write(to: directory.deletingLastPathComponent().appendingPathComponent(file.path), options: .atomic)
    }

    /// A v1-shaped identity (`hc1:` and 64 hex digits) derived from `text`.
    static func identity(_ text: String) -> String {
        "hc1:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A valid v1 event off the fixture: its ID is derived from profile, session and sequence.
    static func event(profile: String, sequence: Int, session: String, routing: String? = nil, root: String? = nil,
                      previous: String? = nil, at: String = "2026-09-24T10:03:00Z", used: Int? = 250) -> [String: Any] {
        return [
            "contract_version": "hermes-context.v1",
            "kind": "model_request",
            "event_id": identity("\(profile)/\(session)/\(sequence)"),
            "sequence": sequence,
            "routing_id": routing ?? identity("\(profile)/lane"),
            "lineage_root_id": root ?? session,
            "previous_session_id": previous ?? NSNull(),
            "session_id": session,
            "timestamp": at,
            "profile": profile,
            "model": "model-x",
            "provider": "provider-x",
            "state": "working",
            "context": [
                "used": used ?? NSNull(), "maximum": used == nil ? NSNull() : 1000,
                "percentage": used.map { Double($0) / 10 } ?? NSNull(),
                "source": used == nil ? NSNull() : "provider_reported", "measured_at": used == nil ? NSNull() : at,
            ] as [String: Any],
        ]
    }

    /// A valid v1 tool call off the fixture, in the same lane as `event`, issued by `request` (an event ID).
    static func toolCall(profile: String, sequence: Int, session: String, request: String) -> [String: Any] {
        [
            "contract_version": "hermes-context.v1",
            "kind": "tool_call",
            "event_id": identity("\(profile)/\(session)/call/\(sequence)"),
            "sequence": sequence,
            "routing_id": identity("\(profile)/lane"),
            "lineage_root_id": session,
            "previous_session_id": NSNull(),
            "session_id": session,
            "request_event_id": request,
            "timestamp": "2026-09-24T10:03:10Z",
            "profile": profile,
            "tool_name": "terminal",
            "skill_name": NSNull(),
            "estimated_tokens": 120,
            "duration_ms": 15,
            "status": "ok",
        ]
    }

    /// This test process's start as Hermes records a gateway's on macOS: creation time in centiseconds since the epoch.
    /// The process stands in for a live gateway, so a status file must carry its real start to pass the pid-reuse guard.
    static let gatewayStartTime = Int(GatewayStatus.processStart(getpid())!)
    static let gatewayStarted = Date(timeIntervalSince1970: Double(gatewayStartTime) / 100)

    /// Hermes's `gateway_state.json` for `pid`, started at `gatewayStartTime`. The command line and agent keys ride
    /// along because the app must never map them; `also` edits the record further.
    static func gatewayStatus(pid: Int32 = getpid(), served: [String] = [],
                              also: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var record: [String: Any] = [
            "pid": pid, "kind": "hermes-gateway", "argv": ["hermes", "gateway", "run"], "start_time": gatewayStartTime,
            "gateway_state": "running", "active_agents": 1, "served_profiles": served,
            "platforms": ["discord": ["state": "connected"]],
        ]
        also(&record)
        return try JSONSerialization.data(withJSONObject: record)
    }

    /// Writes `body` as the `gateway_state.json` of a profile's home (`nil` is the root), and returns that file.
    @discardableResult
    static func writeGatewayStatus(_ body: Data, profile: String?, root: URL) throws -> URL {
        let file = home(profile, root: root).appendingPathComponent(GatewayStatus.fileName)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file)
        return file
    }

    /// A profile's home under `root`: `profiles/<name>`, or the root itself for `nil`.
    static func home(_ profile: String?, root: URL) -> URL {
        profile.map { root.appendingPathComponent("profiles/\($0)", isDirectory: true) } ?? root
    }

    /// A pid whose process has exited and been reaped.
    static let deadPID: Int32 = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }()

    static func write(_ body: Data, profile: String, root: URL) throws {
        let directory = home(profile, root: root).appendingPathComponent(BridgeLocation.snapshotSuffix).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".snapshot.json.\(UUID().uuidString).tmp")
        try body.write(to: temporary)
        guard rename(temporary.path, directory.appendingPathComponent("snapshot.json").path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
