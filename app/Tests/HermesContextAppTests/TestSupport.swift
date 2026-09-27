import Foundation
import ServiceManagement
@testable import HermesContext
@testable import HermesContextCore

/// Stands in for `SMAppService.mainApp`, so no test registers a login item on the Mac running it.
@MainActor
final class FakeLoginItem: LoginItem {
    var status: SMAppService.Status = .notRegistered
    var calls: [String] = []

    func register() throws {
        calls.append("register")
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }
}

/// App settings in a defaults domain named after the test, cleared before and after, so nothing lands in the
/// app's real domain and runs reuse one domain per test instead of piling up plists.
@MainActor
func withSettings(firstRunDone: Bool = true, test: String = #function, _ body: (AppSettings, String) throws -> Void) throws {
    let (settings, suite) = testSettings(test, firstRunDone: firstRunDone)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    try body(settings, suite)
}

/// `withSettings` for a test that awaits: a store's imports land on the main actor only while the test is suspended.
@MainActor
func withSettings(firstRunDone: Bool = true, test: String = #function, _ body: (AppSettings, String) async throws -> Void) async throws {
    let (settings, suite) = testSettings(test, firstRunDone: firstRunDone)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    try await body(settings, suite)
}

@MainActor
private func testSettings(_ test: String, firstRunDone: Bool) -> (AppSettings, String) {
    let suite = "dev.banozz0.hermes-context.tests.app.\(test.prefix { $0 != "(" })"
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    if firstRunDone { settings.recordLaunchAtLogin(false) }
    return (settings, suite)
}
