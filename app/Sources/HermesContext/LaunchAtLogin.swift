import Foundation
import HermesContextCore
import Observation
import ServiceManagement

/// The system login item for this app. A seam so tests never register anything on the Mac running them.
@MainActor
protocol LoginItem {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItem {}

/// Applies the launch-at-login answer to the login item and records it in settings. Only first run and
/// the Settings toggle call `set`; nothing registers at launch on its own.
@MainActor
@Observable
final class LaunchAtLogin {
    @ObservationIgnored private let item: LoginItem
    @ObservationIgnored private let settings: AppSettings
    /// The last registration failure, shown in Settings until the next attempt.
    private(set) var error: String?
    /// The login item's status as last read; `refresh` picks up approvals made in System Settings.
    private(set) var status: SMAppService.Status

    init(item: LoginItem = SMAppService.mainApp, settings: AppSettings) {
        self.item = item
        self.settings = settings
        status = item.status
    }

    /// On once registered, including while macOS waits for approval in Login Items.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = item.status }

    /// Records the explicit choice even when macOS refuses it, so first run never asks twice.
    func set(_ enabled: Bool) {
        settings.recordLaunchAtLogin(enabled)
        do {
            if enabled != isEnabled { try enabled ? item.register() : item.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
