import Foundation
import Testing
@testable import HermesContextCore

@Suite struct BridgeTests {
    @Test func discoversDefaultAndNamedProfilesOnly() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        // A profile without the plugin, and the default home publishing gamma.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("profiles/researcher/sessions"), withIntermediateDirectories: true)
        let defaultHome = root.appendingPathComponent("hermes-context/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try Fixtures.data(Fixtures.gamma).write(to: defaultHome.appendingPathComponent("snapshot.json"))

        let prefix = root.standardizedFileURL.path + "/"
        let found = BridgeLocation(root: root).discoverSnapshots().map { $0.path.replacingOccurrences(of: prefix, with: "") }
        #expect(found == [
            "hermes-context/v1/snapshot.json",
            "profiles/alpha/hermes-context/v1/snapshot.json",
            "profiles/beta/hermes-context/v1/snapshot.json",
        ])

        let reading = BridgeReading.read(BridgeLocation(root: root))
        #expect(reading.failures.isEmpty)
        #expect(reading.snapshots.map(\.profile) == ["gamma", "alpha", "beta"])
        let list = SessionList(snapshots: reading.snapshots, now: Fixtures.now)
        #expect(list.all.count == 7)
    }

    @Test func oneCorruptProfileDoesNotBlankTheOthers() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.write(Data("{\"contract_version\":".utf8), profile: "broken", root: root)

        let reading = BridgeReading.read(BridgeLocation(root: root))
        #expect(reading.snapshots.map(\.profile) == ["alpha", "beta"])
        #expect(reading.failures.map { $0.file.pathComponents.suffix(4).first } == ["broken"])
        #expect(SessionList(snapshots: reading.snapshots, now: Fixtures.now).current.count == 3)
    }

    @Test func atomicNewGenerationOnDiskKeepsOneRow() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alphaBeforeReset, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        let location = BridgeLocation(root: root)

        let before = SessionList(snapshots: BridgeReading.read(location).snapshots, now: Fixtures.now)
        try Fixtures.install(Fixtures.alpha, profile: "alpha", root: root)
        let after = SessionList(snapshots: BridgeReading.read(location).snapshots, now: Fixtures.now)

        #expect(before.current.map(\.id).sorted() == after.current.map(\.id).sorted())
        #expect(before.current.map(\.sessionID).sorted() == ["alpha-1", "alpha-2", "beta-1"])
        #expect(after.current.map(\.sessionID).sorted() == ["alpha-2", "alpha-3", "beta-1"])
    }

    @Test func watcherFiresOnAtomicSnapshotReplacement() async throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alphaBeforeReset])
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = AsyncStream.makeStream(of: Void.self)
        let watcher = BridgeWatcher(location: BridgeLocation(root: root)) { changes.continuation.yield() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))  // FSEvents starts from "now"; let the stream settle

        try Fixtures.install(Fixtures.alpha, profile: "alpha", root: root)
        let fired = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in changes.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            changes.continuation.finish()
            return first
        }
        #expect(fired)
        #expect(BridgeReading.read(BridgeLocation(root: root)).snapshots.first?.sessions.contains { $0.sessionID == "alpha-3" } == true)
    }

    @Test func relevantPathsAreSnapshotsEventsAndProfiles() {
        #expect(BridgeLocation.isRelevant(path: "/private/var/x/profiles/harry/hermes-context/v1/snapshot.json"))
        #expect(BridgeLocation.isRelevant(path: "/Users/someone/.hermes/profiles/newcomer"))
        #expect(!BridgeLocation.isRelevant(path: "/Users/someone/.hermes/profiles/harry/hermes-context/v1/.snapshot.json.1.tmp"))
        #expect(!BridgeLocation.isRelevant(path: "/Users/someone/.hermes/logs/gateway.log"))
        let segment = "/Users/someone/.hermes/profiles/harry/hermes-context/v1/events/000001"
        #expect(BridgeLocation.isRelevant(path: "\(segment)/000000000001-hc1:\(String(repeating: "a", count: 64)).json"))
        #expect(!BridgeLocation.isRelevant(path: "\(segment)/.123.456.abc.tmp"))
        #expect(!BridgeLocation.isRelevant(path: "/Users/someone/.hermes/profiles/harry/hermes-context/v1/generations/ab.json"))
    }
}

/// A gateway Hermes runs whose plugin stays silent. The live gateway is this test process: its pid and real start time
/// pass Hermes's pid-reuse guard, and a reaped pid stands in for a gateway that is gone.
@Suite struct NotReportingTests {
    /// Two minutes into the gateway's run.
    static let now = Fixtures.gatewayStarted.addingTimeInterval(120)

    static func note(_ profile: String) -> String {
        "\(profile): Hermes runs \(profile), but Hermes Context gets nothing from it. Rerun the install line."
    }

    /// Every diagnostic as `profile: message`, read at `now`, for a throwaway Hermes root that `populate` lays out.
    static func lines(at now: Date = now, _ populate: (URL) throws -> Void) throws -> [String] {
        lines(try BridgeState.reading([:], populate: populate), at: now)
    }

    static func lines(_ state: BridgeState, at now: Date = now) -> [String] {
        let diagnostics = state.diagnostics(now: now)
        #expect(Set(diagnostics.map(\.id)).count == diagnostics.count)  // the popover's ForEach needs unique IDs
        return diagnostics.map { "\($0.profile): \($0.message(now: now))" }
    }

    /// `fixture` published as `profile`, its gateway's last beat `age` seconds before `now` (the timeout is 45).
    static func publish(_ fixture: String, profile: String, root: URL, age: TimeInterval) throws {
        try Fixtures.write(Fixtures.beating(fixture, at: now.addingTimeInterval(-age)), profile: profile, root: root)
    }

    @Test func runningGatewayWithNoSnapshotIsNotReporting() throws {
        #expect(try Self.lines { try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "beta", root: $0) } == [Self.note("beta")])
    }

    @Test func staleSnapshotOfARunningGatewayIsNotReportingInsteadOfOffline() throws {
        #expect(try Self.lines { root in
            try Self.publish(Fixtures.alpha, profile: "alpha", root: root, age: 60)
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "alpha", root: root)
        } == [Self.note("alpha")])
    }

    @Test func freshSnapshotHasNoNote() throws {
        #expect(try Self.lines { root in
            try Self.publish(Fixtures.beta, profile: "beta", root: root, age: 0)
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "beta", root: root)
        }.isEmpty)
    }

    @Test func firstMinuteOfAGatewayHasNoNote() throws {
        let status: (URL) throws -> Void = { try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "beta", root: $0) }
        #expect(try Self.lines(at: Fixtures.gatewayStarted.addingTimeInterval(59), status).isEmpty)
        #expect(try Self.lines(at: Fixtures.gatewayStarted.addingTimeInterval(60), status) == [Self.note("beta")])
    }

    /// The plugin beating again takes the note away on the next read.
    @Test func noteLeavesWhenThePluginReportsAgain() throws {
        let root = try Fixtures.hermesRoot([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "beta", root: root)
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(Self.lines(state) == [Self.note("beta")])
        try Self.publish(Fixtures.beta, profile: "beta", root: root, age: 0)
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(Self.lines(state).isEmpty)
    }

    /// A gateway with some platforms parked still serves, and still runs the plugin.
    @Test func degradedGatewayIsRunning() throws {
        #expect(try Self.lines { root in
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus { $0["gateway_state"] = "degraded" }, profile: "beta", root: root)
        } == [Self.note("beta")])
    }

    /// Hermes's own rule: the root gateway runs the default profile and every profile it lists in `served_profiles`,
    /// whatever a profile's own stale file says.
    @Test func rootGatewayRunsTheProfilesItServes() throws {
        #expect(try Self.lines { root in
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(served: ["default", "beta"]), profile: nil, root: root)
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(pid: Fixtures.deadPID), profile: "beta", root: root)
            try Self.publish(Fixtures.alpha, profile: "alpha", root: root, age: 60)  // not served: Offline only
        } == [Self.note("default"), Self.note("beta"), "alpha: Gateway offline, last heartbeat 1m ago."])
    }

    @Test func deadPidRunsNothing() throws {
        #expect(try Self.lines { root in
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(pid: Fixtures.deadPID, served: ["beta"]), profile: nil, root: root)
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(pid: Fixtures.deadPID), profile: "beta", root: root)
        }.isEmpty)
    }

    /// A live pid whose start time is not the recorded one belongs to another process: the gateway that wrote the file
    /// is gone. The app allows the 2 seconds of drift Hermes's reconciliation allows.
    @Test func recycledPidRunsNothing() throws {
        func lines(startOffBy offset: Int) throws -> [String] {
            try Self.lines { root in
                let status = try Fixtures.gatewayStatus { $0["start_time"] = Fixtures.gatewayStartTime + offset }
                try Fixtures.writeGatewayStatus(status, profile: "beta", root: root)
            }
        }
        #expect(try lines(startOffBy: 200) == [Self.note("beta")])
        #expect(try lines(startOffBy: -200) == [Self.note("beta")])
        #expect(try lines(startOffBy: 201).isEmpty)
        #expect(try lines(startOffBy: -60_000).isEmpty)
    }

    /// A failed read of the snapshot already has its own line, and one file gets one line.
    @Test func unreadableSnapshotShowsOnlyItsReadFailure() throws {
        let lines = try Self.lines { root in
            try Fixtures.write(Data("{".utf8), profile: "beta", root: root)
            try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "beta", root: root)
        }
        #expect(lines.count == 1 && lines[0].hasPrefix("beta: Malformed snapshot"), "\(lines)")
    }

    static let unusableStatus: [(String, Data?)] = [
        ("empty", Data()),
        ("truncated", Data("{\"pid\":".utf8)),
        ("array", Data("[]".utf8)),
        ("pid as text", try? Fixtures.gatewayStatus { $0["pid"] = "\(getpid())" }),
        ("served as text", try? Fixtures.gatewayStatus { $0["served_profiles"] = "alpha" }),
        ("start as text", try? Fixtures.gatewayStatus { $0["start_time"] = "yesterday" }),
        ("no start", try? Fixtures.gatewayStatus { $0.removeValue(forKey: "start_time") }),
        ("no pid", try? Fixtures.gatewayStatus { $0.removeValue(forKey: "pid") }),
        ("pid zero", try? Fixtures.gatewayStatus(pid: 0)),
        ("negative pid", try? Fixtures.gatewayStatus(pid: -1)),
        ("stopped", try? Fixtures.gatewayStatus { $0["gateway_state"] = "stopped" }),
        ("startup failed", try? Fixtures.gatewayStatus { $0["gateway_state"] = "startup_failed" }),
    ]

    /// A status file the app cannot trust adds nothing: the profile falls back to its Offline line as before.
    @Test(arguments: unusableStatus.indices)
    func unusableStatusFileAddsNoNote(index: Int) throws {
        let (name, body) = Self.unusableStatus[index]
        let status = try #require(body, "\(name)")
        let lines = try Self.lines { root in
            try Self.publish(Fixtures.alpha, profile: "alpha", root: root, age: 60)
            try Fixtures.writeGatewayStatus(status, profile: "alpha", root: root)
            try Fixtures.writeGatewayStatus(status, profile: nil, root: root)
        }
        #expect(lines == ["alpha: Gateway offline, last heartbeat 1m ago."], "\(name)")
    }

    @Test func unreadableStatusFileAddsNoNote() throws {
        let lines = try Self.lines { root in
            let file = try Fixtures.writeGatewayStatus(Fixtures.gatewayStatus(), profile: "beta", root: root)
            #expect(chmod(file.path, 0) == 0)
        }
        #expect(lines.isEmpty)
    }
}
