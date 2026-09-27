import Foundation
import Observation

/// The app's own local settings, persisted in `UserDefaults` so they survive relaunch. Nothing here
/// reaches Hermes. `launchAtLoginChoice` stays nil until first run records an explicit answer.
@MainActor
@Observable
public final class AppSettings {
    public static let defaultThreshold: Double = 30
    public static let thresholdRange: ClosedRange<Double> = 1...100
    public static let defaultHideAfterHours = Int(SessionList.defaultHideAfter / 3600)
    public static let hideAfterRange: ClosedRange<Int> = 1...168

    enum Key {
        static let viewMode = "viewMode"
        static let threshold = "contextWarningThreshold"
        static let hideAfterHours = "hideAfterHours"
        static let launchAtLoginChoice = "launchAtLoginChoice"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var viewMode: ViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }

    /// Context percentage at which a lane warns, clamped to 1…100.
    public var threshold: Double {
        get { storedThreshold }
        set {
            storedThreshold = Self.clamp(newValue)
            defaults.set(storedThreshold, forKey: Key.threshold)
        }
    }

    private var storedThreshold: Double

    /// Hours an idle lane may sit before it hides, clamped to 1…168.
    public var hideAfterHours: Int {
        get { storedHideAfterHours }
        set {
            storedHideAfterHours = Self.clamp(newValue)
            defaults.set(storedHideAfterHours, forKey: Key.hideAfterHours)
        }
    }

    private var storedHideAfterHours: Int

    public var hideAfter: TimeInterval { TimeInterval(hideAfterHours) * 3600 }

    /// The answer first run recorded: launch at login or not. Nil means first run has not finished.
    public private(set) var launchAtLoginChoice: Bool?

    public var needsFirstRun: Bool { launchAtLoginChoice == nil }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        viewMode = defaults.string(forKey: Key.viewMode).flatMap(ViewMode.init(rawValue:)) ?? .liveStatus
        storedThreshold = (defaults.object(forKey: Key.threshold) as? Double).map(Self.clamp) ?? Self.defaultThreshold
        storedHideAfterHours = (defaults.object(forKey: Key.hideAfterHours) as? Int).map(Self.clamp) ?? Self.defaultHideAfterHours
        launchAtLoginChoice = defaults.object(forKey: Key.launchAtLoginChoice) as? Bool
    }

    /// Records the launch-at-login answer, from first run or a later change in Settings.
    public func recordLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginChoice = enabled
        defaults.set(enabled, forKey: Key.launchAtLoginChoice)
    }

    static func clamp(_ hours: Int) -> Int {
        min(max(hours, hideAfterRange.lowerBound), hideAfterRange.upperBound)
    }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound) : defaultThreshold
    }
}
