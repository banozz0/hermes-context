import HermesContextCore
import SwiftUI

/// Shown in the popover until the launch-at-login question has an explicit answer.
struct FirstRunView: View {
    static let privacy = "Hermes Context keeps only metadata: session names, states, models, context size and timing. It never stores messages, prompts, responses, reasoning or tool output."
    let onChoose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Hermes Context").font(.headline)
            Text("It shows every Hermes session on this Mac from files each profile writes locally.")
            Text(Self.privacy)
            Text("Context warnings stay in the menu bar; it never sends notifications.")
            Divider()
            Text("Launch Hermes Context at login?").font(.callout.weight(.semibold))
            HStack {
                Spacer()
                Button("Not Now") { onChoose(false) }
                Button("Launch at Login") { onChoose(true) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
    }
}

/// View mode, context warning threshold, idle hide age, launch at login, the way to history export and clear, and the bridge diagnostics.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let bridgeRoot: URL
    let diagnostics: [BridgeDiagnostic]
    let now: Date
    let onBack: () -> Void
    var onInsights: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Settings", onBack: onBack)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("View")
                    Spacer()
                    ViewModePicker(settings: settings)
                }
                HStack {
                    Text("Warn at context")
                    Spacer()
                    TextField("Threshold", value: $settings.threshold, format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text("%")
                    Stepper("Threshold", value: $settings.threshold, in: AppSettings.thresholdRange, step: 5)
                        .labelsHidden()
                }
                HStack {
                    Text("Hide idle sessions after")
                    Spacer()
                    TextField("Hours", value: $settings.hideAfterHours, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text("h")
                    Stepper("Hours", value: $settings.hideAfterHours, in: AppSettings.hideAfterRange)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: launchAtLogin.set))
                        .toggleStyle(.switch)
                    if launchAtLogin.needsApproval {
                        Text("Approve it in System Settings › General › Login Items.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = launchAtLogin.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                HStack {
                    Text("History")
                    Spacer()
                    Button("Export or Clear in Insights…", action: onInsights)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bridge diagnostics").font(.callout.weight(.semibold))
                    Text("Reading \(bridgeRoot.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if diagnostics.isEmpty {
                        Text("All profiles reading normally.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        DiagnosticsView(diagnostics: diagnostics, now: now).padding(.horizontal, -10)
                    }
                }
                Text(FirstRunView.privacy).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
        }
        .onAppear(perform: launchAtLogin.refresh)
    }
}
