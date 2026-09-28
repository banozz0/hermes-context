import Foundation
import Testing
@testable import HermesContextCore

@Suite struct SnapshotDecoderTests {
    @Test func decodesRotatedAlphaLanes() throws {
        let alpha = try Fixtures.snapshot(Fixtures.alpha)
        #expect(alpha.profile == "alpha")
        #expect(alpha.offlineAfterSeconds == 45)
        #expect(alpha.heartbeatAt == (try SnapshotDecoder.parseTimestamp("2026-09-24T10:04:00.000Z")))
        #expect(alpha.sessions.count == 2)

        let first = try #require(alpha.sessions.first { $0.route.threadID == "thread-1" })
        #expect(first.displayName == "First thread")
        #expect(first.sessionID == "alpha-3")
        #expect(first.previousSessionID == "alpha-1")
        #expect(first.lineageRootID == "alpha-1")
        #expect(first.state == .idle)
        #expect(first.route == DiscordRoute(guildID: "guild-1", channelID: "channel-10", threadID: "thread-1", channelLabel: "#ops"))
        #expect(first.context.percentage == nil)
        #expect(first.context.percentText == nil)

        let second = try #require(alpha.sessions.first { $0.route.threadID == "thread-2" })
        #expect(second.state == .working)
        #expect(second.model == "model-a")
        #expect(second.provider == "provider-a")
        #expect(second.turnStartedAt == (try SnapshotDecoder.parseTimestamp("2026-09-24T10:01:00.000Z")))
    }

    @Test func decodesContextToolAndUnthreadedLanes() throws {
        let gamma = try Fixtures.snapshot(Fixtures.gamma)
        #expect(gamma.sessions.count == 4)

        let refactor = try #require(gamma.sessions.first { $0.displayName == "Refactor docs" })
        #expect(refactor.state == .working)
        #expect(refactor.currentTool == "terminal")
        #expect(refactor.context.used == 90_000)
        #expect(refactor.context.maximum == 200_000)
        #expect(refactor.context.percentage == 45)
        #expect(refactor.context.isEstimated == false)
        #expect(refactor.context.percentText == "45%")
        #expect(refactor.context.tokensText == "90k / 200k")

        let deploy = try #require(gamma.sessions.first { $0.displayName == "Deploy review" })
        #expect(deploy.state == .needsAttention)
        #expect(deploy.context.percentText == "23%")
        #expect(deploy.context.tokensText == "45k / 200k")

        // Unthreaded lanes carry Hermes's generated title and no thread.
        let planning = try #require(gamma.sessions.first { $0.displayName == "Weekly planning" })
        #expect(planning.route == DiscordRoute(guildID: "guild-1", channelID: "channel-20", threadID: nil, channelLabel: "#planning"))
        #expect(planning.state == .idle)
    }

    @Test func profileLabelsAreCapitalizedProfileNames() throws {
        let beta = try Fixtures.snapshot(Fixtures.beta)
        #expect(beta.sessions.map(\.profileLabel) == ["Beta"])
    }

    @Test func rejectsUnsupportedContract() throws {
        let body = try String(decoding: Fixtures.data(Fixtures.beta), as: UTF8.self)
            .replacingOccurrences(of: "hermes-context.v1", with: "hermes-context.v2")
        #expect(throws: SnapshotError.unsupportedContract("hermes-context.v2")) {
            try SnapshotDecoder.decode(Data(body.utf8))
        }
    }

    @Test func rejectsTruncatedAndMisfiledSnapshots() throws {
        let body = try Fixtures.data(Fixtures.beta)
        #expect(throws: SnapshotError.self) { try SnapshotDecoder.decode(body.prefix(body.count / 2)) }

        let misfiled = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: #""profile":"beta","provider""#, with: #""profile":"alpha","provider""#)
        #expect(throws: SnapshotError.profileMismatch(snapshot: "beta", session: "alpha")) {
            try SnapshotDecoder.decode(Data(misfiled.utf8))
        }
    }

    @Test(arguments: [
        (#""freshness":"live""#, #""freshness":"stale""#),
        (#""percentage":45.0"#, #""percentage":145.0"#),
        (#""used":90000"#, #""used":-1"#),
    ])
    func rejectsValuesTheContractForbids(original: String, replacement: String) throws {
        let body = try String(decoding: Fixtures.data(Fixtures.gamma), as: UTF8.self)
        #expect(body.contains(original))
        #expect(throws: SnapshotError.self) {
            try SnapshotDecoder.decode(Data(body.replacingOccurrences(of: original, with: replacement).utf8))
        }
    }

    @Test func rejectsDuplicateLanesInOneSnapshot() throws {
        let body = try String(decoding: Fixtures.data(Fixtures.alpha), as: UTF8.self)
        let ids = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let lanes = (ids["sessions"] as! [[String: Any]]).map { $0["routing_id"] as! String }
        let duplicated = body.replacingOccurrences(of: lanes[1], with: lanes[0])
        #expect(throws: SnapshotError.malformed("duplicate routing_id")) {
            try SnapshotDecoder.decode(Data(duplicated.utf8))
        }
    }

    /// The closed v1 feature set; absent means nothing lost.
    static let features = ["attention", "backfill", "context_window", "lineage", "sessions", "startup", "subagents",
                           "titles", "tool_history"]

    @Test func degradedNamesTheFeaturesAHermesUpdateSwitchedOff() throws {
        #expect(try Fixtures.snapshot(Fixtures.beta).degraded.isEmpty)
        let every = try SnapshotDecoder.decode(Fixtures.mutate(Fixtures.beta) { $0["degraded"] = Self.features })
        #expect(every.degraded.map(\.rawValue) == Self.features)
        let titles = try SnapshotDecoder.decode(Fixtures.mutate(Fixtures.beta) { $0["degraded"] = ["titles"] })
        #expect(titles.degraded == [.titles])
    }

    @Test(arguments: [["title"], ["titles", "titles"], ["AttributeError: get_session_title"]])
    func rejectsDegradedNamesOutsideTheClosedSet(degraded: [String]) throws {
        #expect(throws: SnapshotError.self) {
            try SnapshotDecoder.decode(Fixtures.mutate(Fixtures.beta) { $0["degraded"] = degraded })
        }
    }

    @Test func estimatedOccupancyIsDisclosed() {
        let estimate = ContextOccupancy(used: 1_500, maximum: 128_000, percentage: 1.171875, source: "estimated", measuredAt: nil)
        #expect(estimate.isEstimated)
        #expect(estimate.percentText == "~1%")
        #expect(estimate.tokensText == "1.5k / 128k")
    }
}
