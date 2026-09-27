import AppKit
import Vision
import SwiftUI
import Testing
@testable import HermesContext
@testable import HermesContextCore

/// Native smoke: the real popover views, hosted in a borderless window that is never ordered in, rendered
/// to a bitmap and read back with Vision (an offscreen SwiftUI host has no accessibility tree).
@MainActor
@Suite(.serialized) struct DetailViewSmokeTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/v1", isDirectory: true)
    static let now = try! SnapshotDecoder.parseTimestamp("2026-09-24T10:05:00.000Z")

    static func snapshot(_ name: String) throws -> ProfileSnapshot {
        try SnapshotDecoder.decode(Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    /// Lays the view out in a window that is never ordered in, renders it to a bitmap, and returns the
    /// text Vision reads off that bitmap, one line per observation, top to bottom.
    static func texts<V: View>(_ view: V, size: NSSize = NSSize(width: 360, height: 560)) throws -> [String] {
        try read(host(view, size: size))
    }

    static var windows: [NSWindow] = []
    static var renders = 0

    /// The view laid out in a borderless window that is never ordered in; the window lives as long as the host.
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 360, height: 560)) -> NSView {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color.white))
        host.sizingOptions = []  // keep the requested size; a tall ideal height would otherwise stretch the bitmap
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)  // an NSView holds its window weakly
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return host
    }

    static func read(_ host: NSView) throws -> [String] {
        try observations(host).map(\.text)
    }

    /// Each line Vision reads, with its box normalised to the view (origin bottom-left).
    static func observations(_ host: NSView) throws -> [(text: String, box: CGRect)] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let size = host.bounds.size
        // Retina density: caption text at 1x is too small for Vision to read reliably.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        // `HERMES_CONTEXT_TEST_RENDERS=<dir>` keeps every rendered bitmap as a PNG for a human to look at.
        if let directory = ProcessInfo.processInfo.environment["HERMES_CONTEXT_TEST_RENDERS"] {
            renders += 1
            let name = "\(Test.current?.name.prefix { $0 != "(" } ?? "render")-\(renders).png"
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        // Vision reads the middle dot as a bullet.
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string.replacingOccurrences(of: "•", with: "·"), observation.boundingBox) }
        }
    }

    /// Clicks the text Vision finds reading `label`, compared through `fold`: mouse down and up at its centre, sent through
    /// the offscreen window the way a real click arrives. Returns false when no such text is drawn.
    @discardableResult
    static func click(_ label: String, in host: NSView) throws -> Bool {
        guard let box = try observations(host).first(where: { fold($0.text) == fold(label) })?.box, let window = host.window else { return false }
        // Vision boxes and window coordinates both start bottom-left; the host fills the window.
        let point = NSPoint(x: box.midX * host.bounds.width, y: box.midY * host.bounds.height)
        try orderedIn(window) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        return true
    }

    /// SwiftUI ignores events in a window that was never ordered in. Orders it in fully transparent, blind to the
    /// real mouse and without activating the test process, so nothing reaches Sven's screen or focus, for `body` only.
    static func orderedIn(_ window: NSWindow, _ body: () throws -> Void) rethrows {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try body()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    /// Vision confuses i, l, 1 and | at caption size, stutters them around an "ffl" ligature ("offililne"),
    /// sometimes drops a middle dot, reads an ellipsis as three dots, and may split a grid row into two observations;
    /// fold all of that on both sides of a comparison.
    static func fold(_ text: String) -> String {
        var folded = ""
        for character in text.replacingOccurrences(of: "…", with: "...") where character != "·" {
            let mapped: Character = "il1|I".contains(character) ? "l" : character
            if mapped == "l", folded.last == "l" { continue }
            folded.append(mapped)
        }
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func detailViewShowsEveryApprovedFieldAndTheDiscordAction() throws {
        let session = try #require(try Self.snapshot("list/gamma.snapshot.json").sessions.first { $0.displayName == "Refactor docs" })
        let details = SessionDetails(session: session, isOffline: false, now: Self.now)
        var opened: DiscordDestination?
        let texts = try Self.texts(SessionDetailView(details: details, onBack: {}, onOpenDiscord: { opened = $0 }))
        let joined = Self.fold(texts.joined(separator: "\n"))
        for field in details.fields {
            #expect(joined.contains(Self.fold("\(field.label) \(field.value)")), "missing \(field.label): \(field.value) in \(texts)")
        }
        #expect(texts.first == "< Refactor docs", "back chevron, then the title")
        #expect(texts.contains("Open Discord"))
        #expect(!joined.contains("Offline"))
        #expect(opened == nil)
    }

    @Test func offlineDetailViewIsMarkedOffline() throws {
        let session = try #require(try Self.snapshot("alpha.snapshot.json").sessions.first { $0.displayName == "Second thread" })
        let texts = try Self.texts(SessionDetailView(details: SessionDetails(session: session, isOffline: true, now: Self.now), onBack: {}, onOpenDiscord: { _ in }))
        #expect(texts.contains("Offline"))
        #expect(Self.fold(texts.joined(separator: "\n")).contains(Self.fold("Working (last known, gateway offline)")))
    }

    /// The real popover over a fixture root: a stale profile's rows stay listed and marked Offline, a
    /// corrupt profile surfaces as a diagnostic, and selecting a row swaps the list for its details.
    @Test func popoverListsOfflineRowsDiagnosesAndOpensDetails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (profile, fixture) in ["alpha": "alpha.snapshot.json", "beta": "beta.snapshot.json", "broken": nil as String?] {
            let directory = root.appendingPathComponent("profiles/\(profile)/hermes-context/v1", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let body = try fixture.map { try Data(contentsOf: Self.fixtures.appendingPathComponent($0)) } ?? Data("{".utf8)
            try body.write(to: directory.appendingPathComponent("snapshot.json"))
        }
        try withSettings { settings, _ in
            // An hour after the fixtures: both heartbeats are stale, yet no idle lane has aged past the hide age.
            let store = LiveStore(location: BridgeLocation(root: root), settings: settings, check: nil, clock: { Self.now.addingTimeInterval(3_600) })
            store.reload()

            let list = try Self.texts(PopoverView(store: store, launchAtLogin: LaunchAtLogin(item: FakeLoginItem(), settings: settings)))
            let joined = Self.fold(list.joined(separator: "\n"))
            #expect(joined.contains(Self.fold("First thread")))
            #expect(joined.contains(Self.fold("Second thread")))
            #expect(list.filter { $0.contains("Offline") }.count >= 3, "\(list)")
            #expect(joined.contains(Self.fold("Broken: Malformed snapshot")))
            #expect(joined.contains(Self.fold("Alpha: Gateway offline, last heartbeat 1h ago")))
            #expect(joined.contains(Self.fold("Beta: Gateway offline, last heartbeat 1h ago")))

            let lane = try #require(store.list.current.first { $0.displayName == "Second thread" })
            store.selection = lane.id
            let details = try Self.texts(PopoverView(store: store, launchAtLogin: LaunchAtLogin(item: FakeLoginItem(), settings: settings)))
            #expect(details.contains("Open Discord"))
            #expect(Self.fold(details.joined(separator: "\n")).contains(Self.fold("Working (last known, gateway offline)")))
            #expect(!details.contains("Search sessions"))
        }
    }

    /// What agents read without a screen: visible rows under `current`, idle lanes past the hide age under
    /// `hidden`, and the setting that decided it.
    @Test func headlessOutputSplitsVisibleAndHiddenLanes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-context-headless-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("profiles/gamma/hermes-context/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: Self.fixtures.appendingPathComponent("list/gamma.snapshot.json"))
            .write(to: directory.appendingPathComponent("snapshot.json"))
        let output = root.appendingPathComponent("check.json")
        try withSettings { settings, _ in
            let check = HeadlessCheck(output: output, seconds: nil, defaultsSuite: nil)
            LiveStore(location: BridgeLocation(root: root), settings: settings, check: check, clock: { Self.now }).reload()
            let body = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
            func names(_ key: String) -> [String] { (body[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
            #expect(names("current") == ["Deploy review", "Refactor docs", "Scratch notes"])
            #expect(names("hidden") == ["Weekly planning"])
            #expect((body["settings"] as? [String: Any])?["hide_after_hours"] as? Int == 24)
        }
    }
}
