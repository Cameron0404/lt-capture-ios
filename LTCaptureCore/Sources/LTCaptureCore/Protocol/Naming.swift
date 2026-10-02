import Foundation

/// File names the Mac expects, per `## Audio notes` and `## Text notes` of the life tracker's
/// `docs/PROTOCOL.md` (plan F80, F82).
///
/// The stem is `yyyy-MM-dd-HHmmss-NNNN`: the local time recording started, in the phone's zone,
/// and four digits that keep two captures in one second apart. The formatter is pinned to
/// `en_US_POSIX` and the Gregorian calendar, so a phone set to a Buddhist or Japanese calendar
/// still writes 2026, not 2569 or Reiwa 8.
public nonisolated enum CaptureNaming {
    /// The date part of every name, before the suffix.
    public static let datePattern = "yyyy-MM-dd-HHmmss"

    /// A formatter for `datePattern` in `zone`, whatever the phone's own locale and calendar.
    public static func formatter(zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = datePattern
        return f
    }

    /// A random suffix from 0 to 9999.
    public static func randomSuffix() -> Int { Int.random(in: 0...9999) }

    /// `yyyy-MM-dd-HHmmss-NNNN`. `suffix` is taken modulo 10000 and zero-padded to four digits.
    public static func stem(start: Date, zone: TimeZone, suffix: Int) -> String {
        let n = ((suffix % 10000) + 10000) % 10000
        return formatter(zone: zone).string(from: start) + "-" + String(format: "%04d", n)
    }

    /// `<stem>.m4a`
    public static func audioName(stem: String) -> String { stem + ".m4a" }

    /// `<stem>.json`, the sidecar beside the audio.
    public static func sidecarName(stem: String) -> String { stem + ".json" }

    /// `dictation-<stem>.txt`, a text note for the top of `life-tracker-inbox/` (plan A4).
    public static func textName(start: Date, zone: TimeZone, suffix: Int) -> String {
        "dictation-" + stem(start: start, zone: zone, suffix: suffix) + ".txt"
    }
}
