import Foundation
import Testing
@testable import HermesContextCore

/// Settings persistence and the menu-bar status, against the shared fixtures and a throwaway defaults domain.
@MainActor
@Suite struct MenuModesTests {
    /// A defaults domain of its own per test, named after it and cleared before and after, so nothing lands in
    /// the app's real domain and runs reuse one domain per test instead of piling up plists.
    static func withDefaults(test: String = #function, _ body: (String) throws -> Void) rethrows {
        let suite = "dev.banozz0.hermes-context.tests.core.\(test.prefix { $0 != "(" })"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try body(suite)
    }

    static func everyoneLive() throws -> [ProfileSnapshot] {
        try [Fixtures.alpha, Fixtures.beta, Fixtures.gamma].map { try Fixtures.live($0) }
    }

    @Test func freshSettingsDefaultToLiveStatusThirtyPercentAndFirstRun() throws {
        try Self.withDefaults { suite in
            let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(settings.viewMode == .liveStatus)
            #expect(settings.threshold == 30)
            #expect(settings.needsFirstRun)
            #expect(settings.launchAtLoginChoice == nil)
        }
    }

    @Test func modeThresholdAndLaunchChoiceSurviveRelaunch() throws {
        try Self.withDefaults { suite in
            let first = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
            first.viewMode = .minimal
            first.threshold = 45
            first.recordLaunchAtLogin(false)

            // A new process reads the domain from disk, not this instance's memory.
            let relaunched = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(relaunched.viewMode == .minimal)
            #expect(relaunched.threshold == 45)
            #expect(relaunched.launchAtLoginChoice == false)
            #expect(!relaunched.needsFirstRun)

            relaunched.viewMode = .liveStatus
            relaunched.recordLaunchAtLogin(true)
            let again = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(again.viewMode == .liveStatus)
            #expect(again.launchAtLoginChoice == true)
        }
    }

    @Test func thresholdClampsAndBadStoredValuesFallBack() throws {
        try Self.withDefaults { suite in
            let defaults = try #require(UserDefaults(suiteName: suite))
            let settings = AppSettings(defaults: defaults)
            settings.threshold = 0
            #expect(settings.threshold == 1)
            settings.threshold = 250
            #expect(settings.threshold == 100)
            settings.threshold = .nan
            #expect(settings.threshold == 30)

            defaults.set("dashboard", forKey: AppSettings.Key.viewMode)
            defaults.set(-5.0, forKey: AppSettings.Key.threshold)
            let reread = AppSettings(defaults: defaults)
            #expect(reread.viewMode == .liveStatus)
            #expect(reread.threshold == 1)
        }
    }

    @Test func iconCountEqualsWorkingLanes() throws {
        let list = SessionList(snapshots: try Self.everyoneLive(), now: Fixtures.now)
        let status = MenuStatus(list: list, threshold: 30)
        let working = list.all.filter { $0.state == .working }
        #expect(working.map(\.displayName).sorted() == ["Refactor docs", "Second thread"])
        #expect(status.workingCount == 2)
        #expect(status.title == "2")

        let idleOnly = SessionList(snapshots: [try Fixtures.live(Fixtures.beta)], now: Fixtures.now)
        #expect(MenuStatus(list: idleOnly, threshold: 30).workingCount == 0)
        #expect(MenuStatus(list: idleOnly, threshold: 30).title == "")
    }

    /// An Offline lane's Working is only its last known state, so it is not counted as working now.
    @Test func offlineWorkingLanesAreNotCounted() throws {
        let snapshots = [try Fixtures.snapshot(Fixtures.alpha), try Fixtures.live(Fixtures.gamma)]
        let list = SessionList(snapshots: snapshots, now: Fixtures.now)
        #expect(list.current.contains { $0.displayName == "Second thread" && $0.state == .working && list.isOffline($0) })
        #expect(MenuStatus(list: list, threshold: 30).workingCount == 1)
    }

    @Test func warningFollowsTheConfiguredPerSessionThreshold() throws {
        let list = SessionList(snapshots: try Self.everyoneLive(), now: Fixtures.now)

        let atDefault = MenuStatus(list: list, threshold: AppSettings.defaultThreshold)
        #expect(atDefault.warnings.map(\.displayName) == ["Refactor docs"])  // 45% ≥ 30; Deploy review is 22.5%
        #expect(atDefault.isWarning)
        #expect(atDefault.symbol == "exclamationmark.triangle.fill")
        #expect(atDefault.warningHeadline == "Context at or above 30%")

        #expect(MenuStatus(list: list, threshold: 20).warnings.map(\.displayName) == ["Refactor docs", "Deploy review"])
        #expect(MenuStatus(list: list, threshold: 45).warnings.map(\.displayName) == ["Refactor docs"], "at the threshold warns")

        let quiet = MenuStatus(list: list, threshold: 46)
        #expect(!quiet.isWarning)
        #expect(quiet.symbol == "bubble.left.and.text.bubble.right")
    }

    /// Any session over the threshold warns, including an idle lane collapsed under Older; an unmeasured lane never does.
    @Test func olderLaneOverThresholdWarnsAndUnmeasuredNeverDoes() throws {
        let gamma = try Fixtures.live(Fixtures.gamma) { object in
            var sessions = object["sessions"] as! [[String: Any]]
            for index in sessions.indices where sessions[index]["display_name"] as? String == "Weekly planning" {
                sessions[index]["context"] = [
                    "used": 180_000, "maximum": 200_000, "percentage": 90.0,
                    "source": "provider_reported", "measured_at": "2026-09-22T09:00:00.000Z",
                ]
            }
            object["sessions"] = sessions
        }
        let list = SessionList(snapshots: [gamma], now: Fixtures.now)
        #expect(list.older.map(\.displayName) == ["Weekly planning"])
        #expect(list.older.first?.context.percentage == 90)
        let status = MenuStatus(list: list, threshold: 30)
        #expect(status.warnings.map(\.displayName) == ["Weekly planning", "Refactor docs"], "fullest first, Older included")
        #expect(status.isWarning)
        #expect(status.symbol == "exclamationmark.triangle.fill")
        #expect(!status.warnings.contains { $0.displayName == "Scratch notes" }, "no measurement, no warning")

        // With only the Older lane over, the icon still warns.
        #expect(MenuStatus(list: list, threshold: 50).warnings.map(\.displayName) == ["Weekly planning"])
    }
}
