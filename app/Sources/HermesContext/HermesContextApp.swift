import AppKit
import HermesContextCore
import SwiftUI

@main
struct HermesContextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var showsMenuBarItem = HeadlessCheck.fromEnvironment() == nil

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarItem) {
            PopoverView(store: delegate.store, launchAtLogin: delegate.launchAtLogin, onInsights: delegate.insights.show)
        } label: {
            LiveMenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reads the store inside a view body, so Observation redraws the icon on every reload and threshold change.
struct LiveMenuBarLabel: View {
    let store: LiveStore

    var body: some View { MenuBarLabel(status: store.status) }
}

/// The menu-bar item: the working count beside the icon, and a warning triangle while any lane is over
/// the context threshold. Warnings stay in the app; there is no notification path.
struct MenuBarLabel: View {
    let status: MenuStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
            if !status.title.isEmpty {
                Text(status.title).monospacedDigit()
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var parts = ["Hermes Context", "\(status.workingCount) working"]
        if status.isWarning { parts.append("\(status.warnings.count) over \(status.thresholdText) context") }
        return parts.joined(separator: ", ")
    }
}

/// Owns the one live store and starts it at launch, not on first popover open. No Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let check = HeadlessCheck.fromEnvironment()
    lazy var settings = AppSettings(defaults: check?.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard)
    lazy var launchAtLogin = LaunchAtLogin(settings: settings)
    lazy var store: LiveStore = {
        let location = BridgeLocation.fromEnvironment()
        return LiveStore(location: location, settings: settings, check: check, history: TelemetrySync.fromEnvironment(location: location))
    }()
    lazy var insights = InsightsWindow(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        check?.scheduleQuit()
    }
}
