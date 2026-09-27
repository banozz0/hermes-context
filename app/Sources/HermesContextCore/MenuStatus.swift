import Foundation

/// The two popover layouts. Live Status is the detailed row; Minimal keeps name, profile, state and context.
public enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case liveStatus
    case minimal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .liveStatus: "Live Status"
        case .minimal: "Minimal"
        }
    }
}

/// What the menu-bar icon says at a glance: how many lanes are working right now, and which lanes sit at
/// or above the context warning threshold. Computed from the unsearched list so a query never hides either.
public struct MenuStatus: Equatable, Sendable {
    /// Working lanes whose gateway is live. An Offline lane's Working is only its last known state.
    public let workingCount: Int
    /// Every lane, Older included, whose latest occupancy is at or above the threshold, fullest first.
    public let warnings: [LiveSession]
    public let threshold: Double

    public var isWarning: Bool { !warnings.isEmpty }

    public init(list: SessionList, threshold: Double) {
        self.threshold = threshold
        workingCount = list.current.filter { $0.state == .working && !list.isOffline($0) }.count
        warnings = list.all
            .filter { Self.isOver($0, threshold: threshold) }
            .sorted { ($0.context.percentage ?? 0) > ($1.context.percentage ?? 0) }
    }

    /// Per session, against its most recent measurement; an unmeasured lane never warns.
    public static func isOver(_ session: LiveSession, threshold: Double) -> Bool {
        guard let percentage = session.context.percentage else { return false }
        return percentage >= threshold
    }

    /// Text beside the icon: the working count, or nothing when no lane is working.
    public var title: String { workingCount > 0 ? "\(workingCount)" : "" }

    /// The SF Symbol for the icon: a warning triangle replaces the bubbles while any lane is over.
    public var symbol: String { isWarning ? "exclamationmark.triangle.fill" : "bubble.left.and.text.bubble.right" }

    /// `30%`: the threshold as the UI states it.
    public var thresholdText: String { "\(Int(threshold.rounded()))%" }

    /// `Context at or above 30%` headline for the in-app warning.
    public var warningHeadline: String { "Context at or above \(thresholdText)" }
}
