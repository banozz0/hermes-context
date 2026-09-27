import AppKit
import HermesContextCore
import SwiftUI

/// The popover: first run until the launch-at-login question is answered, then the list, a lane's
/// details, or Settings in place.
struct PopoverView: View {
    @Bindable var store: LiveStore
    let launchAtLogin: LaunchAtLogin
    var onInsights: () -> Void = {}
    @State private var showsSettings = false

    var body: some View {
        Group {
            if store.settings.needsFirstRun {
                FirstRunView(onChoose: launchAtLogin.set)
            } else if showsSettings {
                SettingsView(settings: store.settings, launchAtLogin: launchAtLogin, bridgeRoot: store.location.root,
                             diagnostics: store.diagnostics, now: store.now, onBack: { showsSettings = false }, onInsights: onInsights)
            } else if let details = store.details {
                SessionDetailView(details: details, onBack: { store.selection = nil }, onOpenDiscord: store.openDiscord)
            } else {
                SessionListView(store: store, onSettings: { showsSettings = true }, onInsights: onInsights)
            }
        }
        .frame(width: 360)
    }
}

/// The list pane: always-on search, the context warning, one flat list of lanes in the chosen view mode,
/// idle-for-a-day lanes under a collapsed Older. Bridge problems sit above the footer so they are never hidden.
struct SessionListView: View {
    @Bindable var store: LiveStore
    let onSettings: () -> Void
    let onInsights: () -> Void

    var body: some View {
        let list = store.list
        let diagnostics = store.diagnostics
        let status = store.status
        return VStack(spacing: 0) {
            TextField("Search sessions", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            if status.isWarning {
                ContextWarningView(status: status)
                Divider()
            }
            SessionRowsView(list: list, now: store.now, isFiltering: !store.query.isEmpty,
                            mode: store.settings.viewMode, threshold: store.settings.threshold) { store.selection = $0.id }
            if !diagnostics.isEmpty {
                Divider()
                DiagnosticsView(diagnostics: diagnostics, now: store.now)
            }
            Divider()
            HStack(spacing: 6) {
                Text("\(list.current.count + list.older.count) sessions")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                ViewModePicker(settings: store.settings)
                Button(action: onInsights) { Image(systemName: "chart.bar") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("i")
                    .help("Insights")
                    .accessibilityLabel("Insights")
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(",")
                    .accessibilityLabel("Settings")
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// The in-app context warning: every lane, Older included, at or above the threshold, fullest first.
struct ContextWarningView: View {
    let status: MenuStatus
    static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(status.warningHeadline, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(status.warnings.prefix(Self.shown)) { session in
                HStack {
                    Text("\(session.displayName) · \(session.profileLabel)").lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(session.context.percentText ?? "").monospacedDigit()
                }
                .font(.caption)
            }
            if status.warnings.count > Self.shown {
                Text("and \(status.warnings.count - Self.shown) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Rows only, from plain values, so it can be hosted without the running store.
struct SessionRowsView: View {
    let list: SessionList
    let now: Date
    let isFiltering: Bool
    let mode: ViewMode
    let threshold: Double
    var onSelect: (LiveSession) -> Void = { _ in }
    @State private var showsOlder = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if list.isEmpty {
                    Text(isFiltering ? "No matching sessions" : "No Hermes sessions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
                ForEach(list.current) { row($0) }
                if !list.older.isEmpty {
                    // A search must never hide its own matches inside the collapsed group.
                    DisclosureGroup(isExpanded: Binding(get: { showsOlder || isFiltering }, set: { showsOlder = $0 })) {
                        ForEach(list.older) { row($0) }
                    } label: {
                        Text("Older (\(list.older.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxHeight: 460)
    }

    private func row(_ session: LiveSession) -> some View {
        Button { onSelect(session) } label: {
            Group {
                switch mode {
                case .liveStatus: SessionRow(session: session, now: now, isOffline: list.isOffline(session), threshold: threshold)
                case .minimal: MinimalRow(session: session, isOffline: list.isOffline(session), threshold: threshold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Minimal mode: one line per lane with name, profile, state and context percentage only.
struct MinimalRow: View {
    let session: LiveSession
    let isOffline: Bool
    let threshold: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateDot(state: session.state, isOffline: isOffline)
            Text(session.displayName).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text([session.profileLabel, isOffline ? "Offline" : nil, session.state.label].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            ContextPercent(session: session, threshold: threshold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct StateDot: View {
    let state: SessionState
    let isOffline: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isOffline ? 0.35 : 1)
            .accessibilityLabel(isOffline ? "Offline, \(state.label)" : state.label)
    }

    private var color: Color {
        switch state {
        case .needsAttention: .orange
        case .working: .green
        case .idle: .secondary
        }
    }
}

/// A lane's context percentage, orange once it reaches the warning threshold.
struct ContextPercent: View {
    let session: LiveSession
    let threshold: Double

    var body: some View {
        Text(session.context.percentText ?? "—")
            .monospacedDigit()
            .foregroundStyle(MenuStatus.isOver(session, threshold: threshold) ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .help(session.context.tokensText.map { "\($0) tokens in context" } ?? "No context measurement yet")
    }
}

/// Live Status mode: the detailed row.
struct SessionRow: View {
    let session: LiveSession
    let now: Date
    let isOffline: Bool
    let threshold: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateDot(state: session.state, isOffline: isOffline)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(session.profileLabel).fontWeight(.medium)
                    Text("·")
                    if isOffline {
                        Text("Offline").foregroundStyle(.red)
                        Text("·")
                    }
                    Text(session.state.label)
                    if let channel = session.route.channelLabel {
                        Text("·")
                        Text(channel).lineLimit(1)
                    }
                    if let model = session.model {
                        Text("·")
                        Text(model).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                ContextPercent(session: session, threshold: threshold)
                if let idle = session.idleText(now: now) {
                    Text(idle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// One lane's approved live fields, its Discord link, and generation identity for diagnostics.
/// Built from plain values so tests can host it without the running store.
struct SessionDetailView: View {
    let details: SessionDetails
    let onBack: () -> Void
    let onOpenDiscord: (DiscordDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: details.title, onBack: onBack) {
                if details.isOffline {
                    Text("Offline").font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FieldGrid(fields: details.fields)
                    DisclosureGroup("Diagnostics") { FieldGrid(fields: details.diagnostics).padding(.top, 4) }
                        .font(.caption)
                }
                .padding(10)
            }
            .frame(maxHeight: 420)
            Divider()
            HStack {
                Spacer()
                Button("Open Discord") { details.discord.map(onOpenDiscord) }
                    .disabled(details.discord == nil)
                    .help(details.discord?.webURL.absoluteString ?? "No Discord location for this session")
            }
            .padding(10)
        }
    }
}

/// A pane's back chevron and title, then a divider: shared by details and Settings.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back")
            Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(10)
        Divider()
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, onBack: @escaping () -> Void) {
        self.init(title: title, onBack: onBack) { EmptyView() }
    }
}

/// Live Status or Minimal, segmented: in the popover footer and in Settings.
struct ViewModePicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("View", selection: $settings.viewMode) {
            ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

struct FieldGrid: View {
    let fields: [SessionDetails.Field]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(fields) { field in
                GridRow {
                    Text(field.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(field.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

/// Bridge problems: a profile that failed to read or whose gateway went quiet.
struct DiagnosticsView: View {
    let diagnostics: [BridgeDiagnostic]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(diagnostics) { diagnostic in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(diagnostic.profile.prefix(1).uppercased() + diagnostic.profile.dropFirst()): \(diagnostic.message(now: now))")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(diagnostic.file.path)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
