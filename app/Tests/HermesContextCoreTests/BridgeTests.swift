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
        #expect(BridgeLocation.isRelevant(path: "/Users/sven/.hermes/profiles/newcomer"))
        #expect(!BridgeLocation.isRelevant(path: "/Users/sven/.hermes/profiles/harry/hermes-context/v1/.snapshot.json.1.tmp"))
        #expect(!BridgeLocation.isRelevant(path: "/Users/sven/.hermes/logs/gateway.log"))
        let segment = "/Users/sven/.hermes/profiles/harry/hermes-context/v1/events/000001"
        #expect(BridgeLocation.isRelevant(path: "\(segment)/000000000001-hc1:\(String(repeating: "a", count: 64)).json"))
        #expect(!BridgeLocation.isRelevant(path: "\(segment)/.123.456.abc.tmp"))
        #expect(!BridgeLocation.isRelevant(path: "/Users/sven/.hermes/profiles/harry/hermes-context/v1/generations/ab.json"))
    }
}
