import Foundation
import LTCaptureCore

/// When the app's signing profile lapses, for the day-6 banner and the install marker (F8, F67).
///
/// Reads `ExpirationDate` from the bundle's `embedded.mobileprovision`, exact for a free and a paid
/// team, and falls back to the executable's date plus 7 days when there is no profile (a simulator
/// build has none).
enum ProvisioningExpiry {
    static func expiry(bundle: Bundle = .main) -> Date? {
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        let executableDate = bundle.executableURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return ExpiryReminder.expiry(profile: profile, executableDate: executableDate)
    }

    /// The text of `audio/lt-capture-install.txt`, written once per new expiry date (F67). The Mac
    /// takes only `.m4a` from `audio/`, so this file is left alone until the Mac-side brief reads it.
    static func installMarker(expiry: Date, installedAt: Date, version: String) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        return """
        app: LT Capture \(version)
        installed_at: \(f.string(from: installedAt))
        profile_expires_at: \(f.string(from: expiry))

        """
    }
}
