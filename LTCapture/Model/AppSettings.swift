import Foundation
import Observation

/// The two switches the owner sees in Settings, plus the app's own markers (plan `### Data`, **Settings**).
/// The 3 and 45 minute thresholds are constants in `StatusResolver`, not settings.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let silenceStopEnabled = "silenceStopEnabled"
        static let markAsTest = "markAsTest"
        static let onboarded = "onboarded"
        static let installMarkerExpiry = "installMarkerExpiry"
        static let sentTexts = "sentTexts"
    }

    @ObservationIgnored let defaults: UserDefaults

    /// "Stop after silence", on by default (plan `### Stop policy`).
    var silenceStopEnabled: Bool { didSet { defaults.set(silenceStopEnabled, forKey: Key.silenceStopEnabled) } }
    /// "Mark captures as tests": adds `"test": true` to the sidecar.
    var markAsTest: Bool { didSet { defaults.set(markAsTest, forKey: Key.markAsTest) } }
    /// Set when the owner has finished the folder picks, the optional second one included.
    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Key.onboarded) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.silenceStopEnabled: true, Key.markAsTest: false, Key.onboarded: false])
        silenceStopEnabled = defaults.bool(forKey: Key.silenceStopEnabled)
        markAsTest = defaults.bool(forKey: Key.markAsTest)
        onboarded = defaults.bool(forKey: Key.onboarded)
    }

    /// Text notes sent in the last 14 days, so their rows can show the receipt (F23).
    var sentTexts: [SentText] {
        get {
            guard let data = defaults.data(forKey: Key.sentTexts) else { return [] }
            return (try? JSONDecoder().decode([SentText].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.sentTexts) }
    }

    /// The profile expiry the install marker was last written for (F67).
    var installMarkerExpiry: Date? {
        get { defaults.object(forKey: Key.installMarkerExpiry) as? Date }
        set { defaults.set(newValue, forKey: Key.installMarkerExpiry) }
    }
}
