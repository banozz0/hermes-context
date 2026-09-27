import AppKit
import SwiftUI
import Testing
@testable import HermesContext
@testable import HermesContextCore

/// Native smoke for Menu modes: the real popover, menu-bar label, first run and Settings, hosted offscreen
/// over a fixture root whose gateways beat at the pinned clock, read back with Vision.
@MainActor
@Suite(.serialized) struct MenuModesSmokeTests {
    typealias UI = DetailViewSmokeTests

    /// alpha and gamma with a fresh heartbeat: two Working lanes (Second thread, Refactor docs at 45%),
    /// one Needs attention lane at 22.5%.
    static func liveRoot(extra: [String: Data] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-modes-\(UUID().uuidString)", isDirectory: true)
        var files = extra
        for (profile, fixture) in ["alpha": "alpha.snapshot.json", "gamma": "list/gamma.snapshot.json"] {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: UI.fixtures.appendingPathComponent(fixture))) as! [String: Any]
            var gateway = object["gateway"] as! [String: Any]
            gateway["heartbeat_at"] = UI.now.formatted(.iso8601)
            object["gateway"] = gateway
            files[profile] = try JSONSerialization.data(withJSONObject: object)
        }
        for (profile, body) in files {
            let directory = root.appendingPathComponent("profiles/\(profile)/hermes-context/v1", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: directory.appendingPathComponent("snapshot.json"))
        }
        return root
    }

    static func store(_ root: URL, _ settings: AppSettings) -> LiveStore {
        let store = LiveStore(location: BridgeLocation(root: root), settings: settings, check: nil, clock: { UI.now })
        store.reload()
        return store
    }

    /// One whole observation reads `text`: the warning names a lane on its own line.
    static func line(_ text: String, in texts: [String]) -> Bool {
        texts.contains { UI.fold($0) == UI.fold(text) }
    }

    static func popover(_ store: LiveStore, item: FakeLoginItem = FakeLoginItem()) -> PopoverView {
        PopoverView(store: store, launchAtLogin: LaunchAtLogin(item: item, settings: store.settings))
    }

    @Test func liveStatusAndMinimalRenderTheirFields() throws {
        let root = try Self.liveRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, _ in
            let store = Self.store(root, settings)
            #expect(settings.viewMode == .liveStatus)
            let live = try UI.texts(Self.popover(store))
            let liveJoined = UI.fold(live.joined(separator: "\n"))
            #expect(liveJoined.contains(UI.fold("Refactor docs")))
            #expect(liveJoined.contains(UI.fold("Gamma Working #ops model-h")), "\(live)")
            #expect(liveJoined.contains(UI.fold("Alpha Working #ops model-a")), "\(live)")
            #expect(live.contains("45%"))

            settings.viewMode = .minimal
            let minimal = try UI.texts(Self.popover(store))
            let minimalJoined = UI.fold(minimal.joined(separator: "\n"))
            for field in ["Refactor docs", "Gamma Working", "Deploy review", "Gamma Needs attention", "Second thread", "Alpha Working"] {
                #expect(minimalJoined.contains(UI.fold(field)), "missing \(field) in \(minimal)")
            }
            #expect(minimalJoined.contains("45%") && minimalJoined.contains("23%"), "\(minimal)")
            #expect(!minimalJoined.contains("model-"), "Minimal drops the model: \(minimal)")
            #expect(!minimalJoined.contains("#ops"), "Minimal drops the channel: \(minimal)")
        }
    }

    @Test func selectedModeSurvivesRelaunch() throws {
        let root = try Self.liveRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, suite in
            // Switch with a real click on the footer's mode control.
            let host = UI.host(Self.popover(Self.store(root, settings)))
            #expect(settings.viewMode == .liveStatus)
            let clicked = try UI.click("Minimal", in: host)
            #expect(clicked)
            #expect(settings.viewMode == .minimal)
            // A second app instance over the same defaults domain, as after quitting and reopening.
            let relaunched = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(relaunched.viewMode == .minimal)
            let texts = try UI.texts(Self.popover(Self.store(root, relaunched)))
            let joined = UI.fold(texts.joined(separator: "\n"))
            #expect(joined.contains(UI.fold("Refactor docs")))
            #expect(!joined.contains("model-"), "\(texts)")
            #expect(texts.contains("Live Status") && texts.contains("Minimal"), "mode switch in the footer: \(texts)")
        }
    }

    /// The menu-bar window can size the popover down to its minimum; the list and details must still draw there.
    @Test func panesDrawAtThePopoversMinimumSize() throws {
        let root = try Self.liveRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, _ in
            let store = Self.store(root, settings)
            @MainActor func textsAtMinimum() throws -> String {
                let minimum = NSHostingController(rootView: Self.popover(store)).sizeThatFits(in: .zero)
                return UI.fold(try UI.texts(Self.popover(store), size: NSSize(width: 360, height: minimum.height)).joined(separator: "\n"))
            }
            let list = try textsAtMinimum()
            for lane in ["Second thread", "Deploy review"] {
                #expect(list.contains(UI.fold(lane)), "\(lane) missing: \(list)")
            }
            store.selection = try #require(store.list.current.first { $0.displayName == "Deploy review" }).id
            #expect(try textsAtMinimum().contains(UI.fold("Needs attention")))
        }
    }

    @Test func menuBarLabelShowsTheWorkingCount() throws {
        let root = try Self.liveRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, _ in
            let status = Self.store(root, settings).status
            #expect(status.workingCount == 2)
            let texts = try UI.texts(MenuBarLabel(status: status).font(.system(size: 40)).padding(), size: NSSize(width: 200, height: 90))
            #expect(texts.contains("2"), "\(texts)")
        }
    }

    @Test func popoverWarnsAtTheConfiguredThresholdIgnoringSearch() throws {
        let root = try Self.liveRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, _ in
            let store = Self.store(root, settings)
            let atDefault = try UI.texts(Self.popover(store))
            let joined = UI.fold(atDefault.joined(separator: "\n"))
            #expect(joined.contains(UI.fold("Context at or above 30%")), "\(atDefault)")
            #expect(Self.line("Refactor docs · Gamma", in: atDefault))
            #expect(!Self.line("Deploy review · Gamma", in: atDefault))

            // A search that hides the warned lane changes neither the icon nor the warning.
            store.query = "alpha"
            #expect(store.status.workingCount == 2)
            #expect(store.status.warnings.map(\.displayName) == ["Refactor docs"])
            #expect(UI.fold(try UI.texts(Self.popover(store)).joined(separator: "\n")).contains(UI.fold("Context at or above 30%")))
            store.query = ""

            settings.threshold = 20
            let lower = try UI.texts(Self.popover(store))
            #expect(UI.fold(lower.joined(separator: "\n")).contains(UI.fold("Context at or above 20%")))
            #expect(Self.line("Deploy review · Gamma", in: lower), "\(lower)")

            settings.threshold = 50
            #expect(!store.status.isWarning)
            #expect(!UI.fold(try UI.texts(Self.popover(store)).joined(separator: "\n")).contains(UI.fold("Context at or above")))
        }
    }

    @Test func firstRunExplainsPrivacyAndRecordsLaunchAtLogin() throws {
        let root = try Self.liveRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings(firstRunDone: false) { settings, suite in
            let item = FakeLoginItem()
            let host = UI.host(Self.popover(Self.store(root, settings), item: item))
            let texts = try UI.read(host)
            let joined = UI.fold(texts.joined(separator: "\n"))
            #expect(joined.contains(UI.fold("Welcome to Hermes Context")))
            #expect(joined.contains(UI.fold("keeps only metadata")), "\(texts)")
            #expect(joined.contains(UI.fold("It never stores messages, prompts, responses, reasoning or tool output.")), "\(texts)")
            #expect(joined.contains(UI.fold("Launch Hermes Context at login?")))
            #expect(texts.contains("Launch at Login") && texts.contains("Not Now"))
            #expect(!texts.contains("Search sessions"), "the list waits for an answer")
            #expect(item.calls.isEmpty, "nothing registers before the choice")

            let chose = try UI.click("Launch at Login", in: host)
            #expect(chose)
            #expect(item.calls == ["register"])
            #expect(settings.launchAtLoginChoice == true)
            #expect(AppSettings(defaults: try #require(UserDefaults(suiteName: suite))).launchAtLoginChoice == true)
            #expect(try UI.read(host).contains("Search sessions"), "the list follows the answer")
        }
        try withSettings(firstRunDone: false) { settings, _ in
            let item = FakeLoginItem()
            let host = UI.host(Self.popover(Self.store(root, settings), item: item))
            let declined = try UI.click("Not Now", in: host)
            #expect(declined)
            #expect(item.calls.isEmpty, "declining never touches the login item")
            #expect(settings.launchAtLoginChoice == false)
            #expect(!settings.needsFirstRun)
        }
    }

    @Test func settingsExposeModeThresholdLaunchAtLoginAndDiagnostics() throws {
        let root = try Self.liveRoot(extra: ["broken": Data("{".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        try withSettings { settings, _ in
            let store = Self.store(root, settings)
            let item = FakeLoginItem()
            let launch = LaunchAtLogin(item: item, settings: settings)
            let view = SettingsView(settings: settings, launchAtLogin: launch, bridgeRoot: root,
                                    diagnostics: store.diagnostics, now: store.now, onBack: {})
            let host = UI.host(view)
            let texts = try UI.read(host)
            let joined = UI.fold(texts.joined(separator: "\n"))
            for field in ["Settings", "View", "Live Status", "Minimal", "Warn at context", "30", "Launch at login", "Bridge diagnostics", "Broken: Malformed snapshot"] {
                #expect(joined.contains(UI.fold(field)), "missing \(field) in \(texts)")
            }
            #expect(texts.contains { $0.hasPrefix("Reading") })

            // The toggle registers and unregisters through the same path first run uses.
            launch.set(true)
            #expect(item.calls == ["register"] && launch.isEnabled && settings.launchAtLoginChoice == true)
            launch.set(false)
            #expect(item.calls == ["register", "unregister"] && !launch.isEnabled && settings.launchAtLoginChoice == false)

            settings.threshold = 55
            #expect(UI.fold(try UI.read(host).joined(separator: "\n")).contains("55"))
        }
    }

    /// No notification framework, API or permission anywhere in the app: warnings live in the menu only.
    @Test func noNotificationPathExists() throws {
        let app = UI.fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("app", isDirectory: true)
        let forbidden = ["UserNotifications", "UNUserNotificationCenter", "UNNotification", "NSUserNotification", "requestAuthorization", "NSUserNotificationAlertStyle"]
        var scanned = 0
        for folder in ["Sources", "Package.swift", "bundle.sh"] {
            let url = app.appendingPathComponent(folder)
            let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []) + [url]
            for file in files where ["swift", "sh"].contains(file.pathExtension) {
                let text = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for token in forbidden {
                    #expect(!text.contains(token), "\(token) in \(file.lastPathComponent)")
                }
            }
        }
        #expect(scanned >= 10, "scanned \(scanned) files")
    }
}
