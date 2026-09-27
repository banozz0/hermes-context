import Foundation
import Testing
@testable import HermesContextCore

@Suite struct SessionListTests {
    private func everyone() throws -> [ProfileSnapshot] {
        try [Fixtures.alpha, Fixtures.beta, Fixtures.gamma].map(Fixtures.snapshot)
    }

    private func names(_ sessions: [LiveSession]) -> [String] {
        sessions.map { "\($0.profile)/\($0.displayName)" }
    }

    @Test func mergesEveryProfileInPriorityThenRecencyOrder() throws {
        let list = SessionList(snapshots: try everyone(), now: Fixtures.now)
        #expect(names(list.current) == [
            "gamma/Deploy review",   // needs attention
            "gamma/Refactor docs",   // working, 10:03
            "alpha/Second thread",   // working, 10:01
            "beta/First thread",     // idle, 10:05
            "alpha/First thread",    // idle, 10:04
            "gamma/Scratch notes",   // idle, 23.5 hours ago
        ])
        #expect(names(list.hidden) == ["gamma/Weekly planning"])
    }

    @Test func oneProfileInTwoThreadsIsTwoRows() throws {
        let list = SessionList(snapshots: [try Fixtures.snapshot(Fixtures.alpha)], now: Fixtures.now)
        let alpha = list.current.filter { $0.profile == "alpha" }
        #expect(alpha.count == 2)
        #expect(Set(alpha.map(\.route.threadID)) == ["thread-1", "thread-2"])
        #expect(Set(alpha.map(\.id)).count == 2)
    }

    @Test func twoProfilesInOneThreadAreTwoRows() throws {
        let list = SessionList(snapshots: try everyone(), now: Fixtures.now)
        let sharedThread = list.current.filter { $0.route == DiscordRoute(guildID: "guild-1", channelID: "channel-10", threadID: "thread-1", channelLabel: "#ops") }
        #expect(sharedThread.map(\.profile).sorted() == ["alpha", "beta"])
        #expect(Set(sharedThread.map(\.id)).count == 2)
    }

    @Test func newGenerationReplacesTheRowInPlace() throws {
        let beta = try Fixtures.snapshot(Fixtures.beta)
        let before = SessionList(snapshots: [try Fixtures.snapshot(Fixtures.alphaBeforeReset), beta], now: Fixtures.now)
        let after = SessionList(snapshots: [try Fixtures.snapshot(Fixtures.alpha), beta], now: Fixtures.now)

        #expect(before.current.count == 3)
        #expect(after.current.count == 3)
        #expect(Set(before.current.map(\.id)) == Set(after.current.map(\.id)))

        let lane = try #require(before.current.first { $0.profile == "alpha" && $0.route.threadID == "thread-1" }).id
        let old = try #require(before.current.first { $0.id == lane })
        let new = try #require(after.current.first { $0.id == lane })
        #expect(old.sessionID == "alpha-1")
        #expect(old.context.percentText == "30%")
        #expect(new.sessionID == "alpha-3")
        #expect(new.previousSessionID == "alpha-1")
        #expect(new.lineageRootID == old.lineageRootID)
        #expect(new.context.percentText == nil)  // a new generation starts with no occupancy
    }

    @Test func duplicateLaneKeepsTheNewestReading() throws {
        let old = try Fixtures.snapshot(Fixtures.alphaBeforeReset)
        let new = try Fixtures.snapshot(Fixtures.alpha)
        let list = SessionList(snapshots: [new, old], now: Fixtures.now)
        #expect(list.current.filter { $0.profile == "alpha" }.count == 2)
        #expect(list.current.contains { $0.sessionID == "alpha-3" })
        #expect(!list.current.contains { $0.sessionID == "alpha-1" })
    }

    @Test func idleLanesHideAtExactlyTwentyFourHoursByDefault() throws {
        let gamma = try Fixtures.snapshot(Fixtures.gamma)
        let scratch = try #require(gamma.sessions.first { $0.displayName == "Scratch notes" })
        let lastActivity = try #require(scratch.lastActivityAt)

        #expect(SessionList.defaultHideAfter == 24 * 3600)
        let justBefore = SessionList(snapshots: [gamma], now: lastActivity.addingTimeInterval(SessionList.defaultHideAfter - 1))
        #expect(justBefore.current.contains { $0.id == scratch.id })

        let atBoundary = SessionList(snapshots: [gamma], now: lastActivity.addingTimeInterval(SessionList.defaultHideAfter))
        #expect(!atBoundary.current.contains { $0.id == scratch.id })
        #expect(atBoundary.hidden.contains { $0.id == scratch.id })
    }

    @Test func theHideAgeIsTheCallersSetting() throws {
        // Scratch notes last moved 23.5 hours before `now`: visible at the default, hidden at one hour.
        let gamma = try Fixtures.snapshot(Fixtures.gamma)
        let oneHour = SessionList(snapshots: [gamma], now: Fixtures.now, hideAfter: 3600)
        #expect(names(oneHour.hidden) == ["gamma/Scratch notes", "gamma/Weekly planning"])
        #expect(names(oneHour.current) == ["gamma/Deploy review", "gamma/Refactor docs"])
    }

    @Test func aHiddenLaneReturnsAsTheSameRowOnItsNextActivity() throws {
        let stale = try Fixtures.snapshot(Fixtures.gamma)
        let weekly = try #require(stale.sessions.first { $0.displayName == "Weekly planning" })
        #expect(SessionList(snapshots: [stale], now: Fixtures.now).hidden.map(\.id) == [weekly.id])

        let active = try Fixtures.live(Fixtures.gamma) { object in
            var sessions = object["sessions"] as! [[String: Any]]
            for index in sessions.indices where sessions[index]["display_name"] as? String == "Weekly planning" {
                var timing = sessions[index]["timing"] as! [String: Any]
                timing["last_activity_at"] = "2026-09-24T10:04:00.000Z"
                sessions[index]["timing"] = timing
            }
            object["sessions"] = sessions
        }
        let list = SessionList(snapshots: [active], now: Fixtures.now)
        #expect(list.hidden.isEmpty)
        #expect(list.current.contains { $0.id == weekly.id })
    }

    @Test func stalledWorkNeverHides() throws {
        let gamma = try Fixtures.snapshot(Fixtures.gamma)
        let muchLater = SessionList(snapshots: [gamma], now: Fixtures.now.addingTimeInterval(7 * 86_400), hideAfter: 3600)
        #expect(names(muchLater.current) == ["gamma/Deploy review", "gamma/Refactor docs"])
        #expect(muchLater.hidden.count == 2)
    }

    @Test(arguments: [
        ("deploy", ["gamma/Deploy review"]),
        ("GAMMA", ["gamma/Deploy review", "gamma/Refactor docs", "gamma/Scratch notes"]),
        ("model-a", ["alpha/Second thread", "alpha/First thread"]),
        ("first beta", ["beta/First thread"]),
        ("  thread   ALPHA ", ["alpha/Second thread", "alpha/First thread"]),
        ("wéekly", []),       // hidden lanes never match
        ("#planning", []),
        ("planning", []),
        ("ops alpha", ["alpha/Second thread", "alpha/First thread"]),
        ("#OPS deploy", ["gamma/Deploy review"]),
        ("alpha-3", []),      // session IDs are not searchable
        ("channel-10", []),   // neither are raw Discord IDs
    ])
    func searchMatchesNameProfileModelAndChannel(query: String, expected: [String]) throws {
        let list = SessionList(snapshots: try everyone(), query: query, now: Fixtures.now)
        #expect(names(list.current) == expected)
    }

    @Test func emptyQueryShowsEveryVisibleLane() throws {
        let list = SessionList(snapshots: try everyone(), query: "   ", now: Fixtures.now)
        #expect(list.current.count == 6)
        #expect(list.hidden.count == 1)
    }

    @Test func recencyText() throws {
        let beta = try #require(try Fixtures.snapshot(Fixtures.beta).sessions.first)
        #expect(beta.idleText(now: Fixtures.now) == "now")
        #expect(beta.idleText(now: Fixtures.now.addingTimeInterval(4 * 60)) == "4m")
        #expect(beta.idleText(now: Fixtures.now.addingTimeInterval(3 * 3_600)) == "3h")
        #expect(beta.idleText(now: Fixtures.now.addingTimeInterval(2 * 86_400)) == "2d")
    }
}
