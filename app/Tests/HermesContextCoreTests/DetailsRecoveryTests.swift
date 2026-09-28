import Foundation
import Testing
@testable import HermesContextCore

@Suite struct SessionDetailsTests {
    static func session(_ fixture: String, _ name: String, profile: String? = nil) throws -> LiveSession {
        try #require(try Fixtures.snapshot(fixture).sessions.first { $0.displayName == name && (profile == nil || $0.profile == profile) })
    }

    @Test func workingLaneShowsEveryApprovedField() throws {
        let details = SessionDetails(session: try Self.session(Fixtures.gamma, "Refactor docs"), isOffline: false, now: Fixtures.now)
        #expect(details.title == "Refactor docs")
        #expect(details.fields.map(\.label) == ["Profile", "State", "Context", "Model", "Current tool", "Turn started", "Last activity", "Discord"])
        #expect(details.fields.map(\.value) == [
            "Gamma", "Working", "45% · 90k / 200k tokens · measured 2m ago", "model-h · provider-g",
            "terminal", "3m ago", "2m ago", "Thread in #ops",
        ])
        #expect(details.diagnostics.map(\.label) == ["Session", "Previous session", "Lineage root", "Routing"])
        #expect(details.diagnostics.map(\.value).prefix(3) == ["gamma-3", "None", "gamma-3"])
    }

    @Test func idleAndUnthreadedLanesDropTurnFields() throws {
        let planning = SessionDetails(session: try Self.session(Fixtures.gamma, "Weekly planning"), isOffline: false, now: Fixtures.now)
        #expect(planning.fields.map(\.label) == ["Profile", "State", "Context", "Model", "Last activity", "Discord"])
        #expect(planning.fields.last?.value == "#planning")
        #expect(planning.fields[2].value == "No measurement yet")

        let rotated = SessionDetails(session: try Self.session(Fixtures.alpha, "First thread"), isOffline: false, now: Fixtures.now)
        #expect(rotated.diagnostics.map(\.value).prefix(3) == ["alpha-3", "alpha-1", "alpha-1"])
    }

    @Test func offlineDetailsKeepTheLastKnownState() throws {
        let details = SessionDetails(session: try Self.session(Fixtures.alpha, "Second thread"), isOffline: true, now: Fixtures.now)
        #expect(details.isOffline)
        #expect(details.fields[1].value == "Working (last known, gateway offline)")
    }

    /// Off-contract fields a future or hostile writer adds are never decoded, so they cannot reach details;
    /// a tool name left on an idle lane is not shown either.
    @Test func forbiddenContentNeverReachesDetails() throws {
        let data = try Fixtures.mutate(Fixtures.gamma) { snapshot in
            var sessions = snapshot["sessions"] as! [[String: Any]]
            for index in sessions.indices {
                sessions[index]["last_message"] = "SECRET prompt text"
                sessions[index]["tool_arguments"] = ["cmd": "SECRET rm -rf"]
                sessions[index]["reasoning"] = "SECRET chain"
                sessions[index]["current_tool"] = "leftover_tool"
            }
            snapshot["sessions"] = sessions
            snapshot["transcript"] = "SECRET transcript"
        }
        for session in try SnapshotDecoder.decode(data).sessions {
            let details = SessionDetails(session: session, isOffline: false, now: Fixtures.now)
            let text = ([details.title] + (details.fields + details.diagnostics).flatMap { [$0.label, $0.value] }).joined(separator: "\n")
            #expect(!text.contains("SECRET"))
            #expect(text.contains("leftover_tool") == (session.state == .working))
        }
    }
}

@Suite struct DiscordDestinationTests {
    @Test func threadLaneOpensItsExactFixtureThread() throws {
        let session = try SessionDetailsTests.session(Fixtures.gamma, "Refactor docs")
        let destination = try #require(DiscordDestination(session: session))
        #expect(destination.guildID == "guild-1")
        #expect(destination.channelID == "channel-10")
        #expect(destination.threadID == "thread-4")
        #expect(destination.webURL.absoluteString == "https://discord.com/channels/guild-1/thread-4")
        #expect(destination.appURL.absoluteString == "discord://-/channels/guild-1/thread-4")
    }

    @Test func unthreadedLaneOpensItsChannel() throws {
        let destination = try #require(DiscordDestination(session: try SessionDetailsTests.session(Fixtures.gamma, "Weekly planning")))
        #expect(destination.threadID == nil)
        #expect(destination.webURL.absoluteString == "https://discord.com/channels/guild-1/channel-20")
    }

    @Test func twoProfilesInOneThreadShareTheLocationNotTheRow() throws {
        let alpha = try SessionDetailsTests.session(Fixtures.alpha, "First thread")
        let beta = try SessionDetailsTests.session(Fixtures.beta, "First thread")
        #expect(alpha.id != beta.id)
        #expect(DiscordDestination(session: alpha)?.webURL == DiscordDestination(session: beta)?.webURL)
        #expect(DiscordDestination(session: alpha)?.webURL.absoluteString == "https://discord.com/channels/guild-1/thread-1")
    }

    @Test func directMessageUsesMe() throws {
        let data = try Fixtures.mutate(Fixtures.gamma) { snapshot in
            snapshot["sessions"] = (snapshot["sessions"] as! [[String: Any]]).map { row in
                var row = row
                row["discord_route"] = ["guild_id": NSNull(), "channel_id": "dm-7", "thread_id": NSNull(), "channel_label": NSNull()]
                return row
            }
        }
        let session = try #require(try SnapshotDecoder.decode(data).sessions.first)
        #expect(DiscordDestination(session: session)?.webURL.absoluteString == "https://discord.com/channels/@me/dm-7")
    }

    /// guild, channel, thread: path escapes, query injection, a missing channel, non-ASCII.
    static let unsafeRoutes: [(String?, String?, String?)] = [
        ("guild-1", "../../evil", nil),
        ("guild-1", "channel-10", "thread?x=1"),
        ("g/1", "channel-10", nil),
        ("guild-1", nil, nil),
        ("guild-1", "chânnel", nil),
    ]

    @Test(arguments: unsafeRoutes.indices)
    func unsafeOrMissingRoutesGetNoLink(index: Int) throws {
        let (guild, channel, thread) = Self.unsafeRoutes[index]
        let route: [String: Any] = ["guild_id": guild ?? NSNull(), "channel_id": channel ?? NSNull(), "thread_id": thread ?? NSNull()]
        let data = try Fixtures.mutate(Fixtures.gamma) { snapshot in
            var rows = snapshot["sessions"] as! [[String: Any]]
            rows[0]["discord_route"] = route.merging(["channel_label": NSNull()]) { a, _ in a }
            snapshot["sessions"] = rows
        }
        let session = try #require(try SnapshotDecoder.decode(data).sessions.first)
        #expect(DiscordDestination(session: session) == nil)
        #expect(SessionDetails(session: session, isOffline: false, now: Fixtures.now).discord == nil)
    }

    @Test func nonDiscordLaneGetsNoLink() throws {
        let data = try Fixtures.mutate(Fixtures.gamma) { snapshot in
            var rows = snapshot["sessions"] as! [[String: Any]]
            rows[0]["platform"] = "telegram"
            snapshot["sessions"] = rows
        }
        #expect(DiscordDestination(session: try #require(try SnapshotDecoder.decode(data).sessions.first)) == nil)
    }
}

@Suite struct OfflineTests {
    /// alpha's heartbeat is 10:04:00 with a 45-second timeout.
    @Test func heartbeatOlderThanTheTimeoutIsOffline() throws {
        let alpha = try Fixtures.snapshot(Fixtures.alpha)
        #expect(!alpha.isOffline(at: alpha.heartbeatAt.addingTimeInterval(45)))
        #expect(alpha.isOffline(at: alpha.heartbeatAt.addingTimeInterval(46)))
        #expect(!alpha.isOffline(at: alpha.heartbeatAt.addingTimeInterval(-600)))  // a Mac clock behind the writer
    }

    @Test func staleProfileKeepsItsRowsMarkedOfflineBesideAHealthyOne() throws {
        let alpha = try Fixtures.snapshot(Fixtures.alpha)
        let beta = try Fixtures.snapshot(Fixtures.beta)
        let list = SessionList(snapshots: [alpha, beta], now: Fixtures.now)  // alpha 60 s stale, beta fresh
        #expect(list.current.count == 3)
        #expect(list.offline == Set(alpha.sessions.map(\.id)))
        #expect(list.current.filter { list.isOffline($0) }.map(\.state).sorted { $0.rank < $1.rank } == [.working, .idle])

        let diagnostics = try BridgeState.reading(["alpha": Fixtures.alpha, "beta": Fixtures.beta]).diagnostics(now: Fixtures.now)
        #expect(diagnostics.map(\.profile) == ["alpha"])
        #expect(diagnostics.first?.message(now: Fixtures.now) == "Gateway offline, last heartbeat 1m ago.")
    }

    @Test func healthyEmptySnapshotStaysOnline() throws {
        let data = try Fixtures.mutate(Fixtures.beta) { $0["sessions"] = [] }
        let empty = try SnapshotDecoder.decode(data)
        #expect(!empty.isOffline(at: Fixtures.now))
        #expect(SessionList(snapshots: [empty], now: Fixtures.now).isEmpty)

        let root = try Fixtures.hermesRoot([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.write(data, profile: "beta", root: root)
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(state.snapshots.map(\.profile) == ["beta"])
        #expect(state.diagnostics(now: Fixtures.now).isEmpty)
    }

    @Test func writerDeclaredOfflineIsOffline() throws {
        let data = try Fixtures.mutate(Fixtures.beta) { $0["freshness"] = "offline" }
        #expect(try SnapshotDecoder.decode(data).isOffline(at: Fixtures.now))
    }
}

@Suite struct DegradedTests {
    static let rerun = "Rerun the install line for the latest Hermes Context."

    /// beta is live at `Fixtures.now`; `degraded` is what its plugin says a Hermes update switched off.
    static func beta(degraded: [String], alphaDegraded: [String]? = nil) throws -> BridgeState {
        let root = try Fixtures.hermesRoot([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.write(try Fixtures.mutate(Fixtures.beta) { $0["degraded"] = degraded }, profile: "beta", root: root)
        if let alphaDegraded {
            try Fixtures.write(try Fixtures.mutate(Fixtures.alpha) { $0["degraded"] = alphaDegraded }, profile: "alpha", root: root)
        }
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        return state
    }

    @Test func oneLineNamesEveryLostFeatureInUserWords() throws {
        let diagnostics = try Self.beta(degraded: ["titles"]).diagnostics(now: Fixtures.now)
        #expect(diagnostics.map(\.profile) == ["beta"])
        #expect(diagnostics.first?.message(now: Fixtures.now) == "A Hermes update switched off session titles. \(Self.rerun)")

        let three = try Self.beta(degraded: ["context_window", "titles", "tool_history"]).diagnostics(now: Fixtures.now)
        #expect(three.map { $0.message(now: Fixtures.now) } == [
            "A Hermes update switched off context window sizes, session titles and tool history. \(Self.rerun)"])
    }

    @Test func everyFeatureHasItsOwnUserWords() {
        let words = DegradedFeature.allCases.filter { $0 != .sessions }.map(\.userWords)
        #expect(words.count == 8 && Set(words).count == 8)
        #expect(words.allSatisfy { !$0.isEmpty && !$0.contains("_") })
    }

    @Test func lostSessionsSaysItCannotSeeThem() throws {
        let diagnostics = try Self.beta(degraded: ["sessions", "titles"]).diagnostics(now: Fixtures.now)
        #expect(diagnostics.map { $0.message(now: Fixtures.now) } == ["Hermes Context can't see its sessions. \(Self.rerun)"])
    }

    @Test func offlineProfileShowsOnlyItsOfflineLine() throws {
        // alpha is 60 s stale at `Fixtures.now`: its gateway is gone, so its last report is no longer news.
        let diagnostics = try Self.beta(degraded: ["titles"], alphaDegraded: ["lineage"]).diagnostics(now: Fixtures.now)
        #expect(diagnostics.map { "\($0.profile): \($0.message(now: Fixtures.now))" } == [
            "alpha: Gateway offline, last heartbeat 1m ago.",
            "beta: A Hermes update switched off session titles. \(Self.rerun)",
        ])
    }
}

@Suite struct RecoveryTests {
    @Test func corruptProfileKeepsItsLastGoodSnapshotAndDiagnoses() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        let location = BridgeLocation(root: root)
        var state = BridgeState()
        state.apply(BridgeReading.read(location))
        #expect(state.diagnostics(now: Fixtures.now).map(\.profile) == ["alpha"])  // only alpha is stale

        try Fixtures.write(Data("{\"contract_version\":".utf8), profile: "beta", root: root)
        state.apply(BridgeReading.read(location))
        #expect(state.snapshots.map(\.profile) == ["alpha", "beta"])
        #expect(state.snapshots.last?.sessions.map(\.sessionID) == ["beta-1"])
        let beta = try #require(state.diagnostics(now: Fixtures.now).first)
        #expect(beta.profile == "beta")
        guard case .unreadable(_, let retained) = beta.problem else { Issue.record("expected unreadable"); return }
        #expect(retained)
        let message = beta.message(now: Fixtures.now)
        #expect(message.hasPrefix("Malformed snapshot: ") && message.hasSuffix(". Showing its last good snapshot."), "\(message)")
        #expect(!message.contains(".."))

        // The retained snapshot still ages to Offline by its own heartbeat.
        let later = Fixtures.now.addingTimeInterval(120)
        #expect(SessionList(snapshots: state.snapshots, now: later).offline.count == 3)

        try Fixtures.install(Fixtures.beta, profile: "beta", root: root)
        state.apply(BridgeReading.read(location))
        #expect(state.failures.isEmpty)
        #expect(state.diagnostics(now: Fixtures.now).map(\.profile) == ["alpha"])
    }

    @Test func unsupportedNewProfileIsDiagnosedWithoutHidingHealthyOnes() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.write(try Fixtures.mutate(Fixtures.gamma) { $0["contract_version"] = "hermes-context.v2"; $0["sessions"] = "reshaped" },
                           profile: "gamma", root: root)
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(state.snapshots.map(\.profile) == ["alpha", "beta"])
        let gamma = try #require(state.diagnostics(now: Fixtures.now).first)
        #expect(gamma.problem == .unreadable(reason: "Unsupported bridge contract hermes-context.v2", retained: false))
        #expect(gamma.profile == "gamma")
    }

    @Test func removedProfileLeaves() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        try FileManager.default.removeItem(at: root.appendingPathComponent("profiles/beta"))
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(state.snapshots.map(\.profile) == ["alpha"])
        #expect(state.failures.isEmpty)
    }

    static let malformed: [(String, Data?, String)] = [
        ("empty", Data(), "Malformed snapshot"),
        ("truncated", Data("{\"contract_version\":\"hermes-context.v1\",\"profile\":".utf8), "Malformed snapshot"),
        ("binary", Data([0xff, 0xfe, 0x00, 0x9c]), "Malformed snapshot"),
        ("array", Data("[]".utf8), "Malformed snapshot"),
        ("wrong type", try? Fixtures.mutate(Fixtures.gamma) { $0["gateway"] = ["heartbeat_at": 5, "offline_after_seconds": 45] },
         "Malformed snapshot: gateway.heartbeat_at:"),
        ("missing key", try? Fixtures.mutate(Fixtures.gamma) { $0.removeValue(forKey: "profile") }, "Malformed snapshot: profile: missing"),
        ("bad state", try? Fixtures.mutate(Fixtures.gamma) { snapshot in
            var rows = snapshot["sessions"] as! [[String: Any]]
            rows[1]["state"] = "sleeping"
            snapshot["sessions"] = rows
        }, "Malformed snapshot: sessions[1].state:"),
        ("bad timestamp", try? Fixtures.mutate(Fixtures.gamma) { $0["generated_at"] = "yesterday" }, "Invalid timestamp yesterday"),
        ("percentage", try? Fixtures.mutate(Fixtures.gamma) { snapshot in
            var rows = snapshot["sessions"] as! [[String: Any]]
            rows[0]["context"] = ["used": 1, "maximum": 1, "percentage": 150, "source": "provider_reported", "measured_at": NSNull()]
            snapshot["sessions"] = rows
        }, "Malformed snapshot: context.percentage 150"),
        ("directory", nil, "Cannot read snapshot"),
    ]

    @Test(arguments: malformed.indices)
    func malformedFileIsIsolatedAndNamed(index: Int) throws {
        let (name, body, expected) = Self.malformed[index]
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer { try? FileManager.default.removeItem(at: root) }
        if let body {
            try Fixtures.write(body, profile: "broken", root: root)
        } else {
            let path = root.appendingPathComponent("profiles/broken/\(BridgeLocation.snapshotSuffix)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(state.snapshots.map(\.profile) == ["alpha", "beta"], "\(name)")
        let failure = try #require(state.failures.first, "\(name)")
        #expect(failure.profile == "broken")
        #expect(failure.reason.hasPrefix(expected), "\(name): \(failure.reason)")
        #expect(failure.reason.count <= 200 && !failure.reason.contains("\n"), "\(name): \(failure.reason)")
    }

    @Test func unreadableFileIsReportedNotSilentlyDropped() throws {
        let root = try Fixtures.hermesRoot(["alpha": Fixtures.alpha, "beta": Fixtures.beta])
        defer {
            chmod(root.appendingPathComponent("profiles/beta/\(BridgeLocation.snapshotSuffix)").path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
        let beta = root.appendingPathComponent("profiles/beta/\(BridgeLocation.snapshotSuffix)")
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(chmod(beta.path, 0) == 0)
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        #expect(state.snapshots.map(\.profile) == ["alpha", "beta"])  // last good beta retained
        #expect(state.failures.map(\.reason) == ["Snapshot is not readable"])
    }

    @Test func defaultHomeFailureIsNamedDefault() {
        let file = URL(fileURLWithPath: "/tmp/x/.hermes/hermes-context/v1/snapshot.json")
        #expect(BridgeFailure(file: file, reason: "x").profile == "default")
        #expect(BridgeFailure(file: URL(fileURLWithPath: "/tmp/x/.hermes/profiles/harry/hermes-context/v1/snapshot.json"), reason: "x").profile == "harry")
    }
}

extension BridgeState {
    static func reading(_ profiles: [String: String]) throws -> BridgeState {
        let root = try Fixtures.hermesRoot(profiles)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = BridgeState()
        state.apply(BridgeReading.read(BridgeLocation(root: root)))
        return state
    }
}
