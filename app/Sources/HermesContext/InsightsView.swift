import AppKit
import HermesContextCore
import SwiftUI
import UniformTypeIdentifiers

/// The separate Insights window: built on first open, reused after it closes, never shown at launch.
@MainActor
final class InsightsWindow {
    private let store: LiveStore
    private let activate: () -> Void

    lazy var window: NSWindow = {
        let controller = NSHostingController(rootView: InsightsView(store: store))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "Insights"
        window.setContentSize(NSSize(width: 660, height: 560))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Insights")
        return window
    }()

    /// `activate` brings this menu-bar-only app forward so the window takes focus; tests pass a no-op.
    init(store: LiveStore, activate: @escaping () -> Void = { NSApp.activate() }) {
        self.store = store
        self.activate = activate
    }

    func show() {
        activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// History statistics per profile, overall and per session generation grouped by lane, with export and a clear that
/// asks first. Every model request counts once; nothing is time-weighted.
struct InsightsView: View {
    let store: LiveStore
    @State private var confirmingClear = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context usage").font(.title3.weight(.semibold))
                Text("Each model request counts once; statistics are not time-weighted. A request with no context measurement counts toward Requests only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var report: InsightsReport? { store.history.report }

    @ViewBuilder private var content: some View {
        switch store.history {
        case .off:
            Notice(title: "No history in this run", detail: "A fixture or headless run keeps history only when it names a database.")
        case .loading:
            Notice(title: "Loading history…")
        case .unavailable(let reason):
            Notice(title: "History unavailable", detail: "\(reason)\nThe live session list is unaffected.", isWarning: true)
        case .ready(let report) where report.overall.requests == 0:
            Notice(title: "No model requests recorded yet")
        case .ready(let report):
            InsightsReportView(report: report, lanes: store.allLanes.all)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if confirmingClear, let report {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Clear all history?", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("This deletes \(Self.summary(report, joinedBy: ", ")) and anything published since from this Mac. It cannot be undone; Hermes sessions, snapshots and transcripts are not touched.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { confirmingClear = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Clear All History", role: .destructive) {
                            confirmingClear = false
                            Task {
                                await store.clearHistory()
                                message = self.report == nil ? nil : "History cleared."
                            }
                        }
                    }
                }
                Divider()
            }
            HStack(spacing: 8) {
                Text(message ?? report.map { Self.summary($0, joinedBy: " · ") } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Export CSV…") { export(.csv) }
                Button("Export JSON…") { export(.json) }
                Button("Clear History…") {
                    message = nil
                    confirmingClear = true
                }
                .disabled(report.map { $0.overall.requests + $0.toolCalls } == 0)
            }
            .disabled(report == nil)
        }
        .padding(12)
    }

    private func export(_ format: HistoryExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "Hermes Context history \(Date().formatted(.iso8601.year().month().day())).\(format.rawValue)"
        // Not modal: the bridge tick and imports keep running while the panel is open.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await store.exportHistory(format, to: url)
                    message = "Exported to \(url.lastPathComponent)."
                } catch {
                    message = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// `3 model requests and 5 tool calls`.
    static func summary(_ report: InsightsReport, joinedBy separator: String) -> String {
        count(report.overall.requests, "model request") + separator + count(report.toolCalls, "tool call")
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

/// The statistics tables: overall and every profile, then each lane's generations, labelled current or ended.
struct InsightsReportView: View {
    let report: InsightsReport
    /// Live lanes by routing ID: a lane's name, and which of its generations is current.
    private let live: [String: LiveSession]
    @State private var collapsed: Set<String> = []

    init(report: InsightsReport, lanes: [LiveSession]) {
        self.report = report
        live = Dictionary(lanes.map { ($0.id, $0) }) { first, _ in first }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("By profile").font(.headline)
                table(profileRows, boldFirst: true)
                Text("By session").font(.headline).padding(.top, 6)
                ForEach(report.lanes) { lane in
                    DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(lane.id) },
                                                        set: { if $0 { collapsed.remove(lane.id) } else { collapsed.insert(lane.id) } })) {
                        table(generationRows(lane)).padding(.vertical, 4)
                    } label: {
                        Text("\(name(lane)) · \(LiveSession.profileLabel(lane.profile)) · \(InsightsView.count(lane.generations.count, "generation"))")
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(12)
        }
    }

    /// A table row as drawn: its label, then Requests, Measured, Mean, Median and Peak.
    struct Row {
        let label: String
        let cells: [String]

        init(_ label: String, _ statistics: ContextStatistics) {
            self.label = label
            cells = ["\(statistics.requests)", "\(statistics.measured)"] + [statistics.mean, statistics.median, statistics.peak].map(InsightsReportView.percent)
        }
    }

    var profileRows: [Row] {
        [Row("All profiles", report.overall)] + report.profiles.map { Row(LiveSession.profileLabel($0.profile), $0.statistics) }
    }

    func generationRows(_ lane: InsightsReport.Lane) -> [Row] {
        lane.generations.map { Row("\(status(lane, $0)), from \($0.generation.firstAt.formatted(date: .abbreviated, time: .shortened))", $0.statistics) }
    }

    private func table(_ rows: [Row], boldFirst: Bool = false) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(["Requests", "Measured", "Mean", "Median", "Peak"], id: \.self) { Text($0).gridColumnAlignment(.trailing) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    Text(row.label).lineLimit(1)
                    ForEach(row.cells.indices, id: \.self) { Text(row.cells[$0]) }
                }
                .fontWeight(boldFirst && index == 0 ? .semibold : nil)
                .monospacedDigit()
            }
        }
    }

    /// The live lane's name, else when history first saw the lane: history keeps no names.
    func name(_ lane: InsightsReport.Lane) -> String {
        live[lane.routingID]?.displayName
            ?? "Lane first seen \(lane.generations[0].generation.firstAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Current when the live lane runs it, ended when a later generation replaced it; a lane that is no longer live
    /// shows its newest generation as latest.
    func status(_ lane: InsightsReport.Lane, _ generation: InsightsReport.GenerationStatistics) -> String {
        let current = live[lane.routingID]?.sessionID
        if current == generation.id { return "Current" }
        if current == nil, generation.id == lane.generations.last?.id { return "Latest" }
        return "Ended"
    }

    /// `32.5%`, or a dash with no measurement.
    nonisolated static func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—"
    }
}

/// A centred message in place of the tables.
private struct Notice: View {
    let title: String
    var detail: String?
    var isWarning = false

    var body: some View {
        VStack(spacing: 6) {
            Label(title, systemImage: isWarning ? "exclamationmark.triangle.fill" : "chart.bar")
                .font(.headline)
                .foregroundStyle(isWarning ? Color.orange : Color.primary)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
