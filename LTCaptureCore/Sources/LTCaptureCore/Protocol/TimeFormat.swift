import Foundation

/// `spoken_at` for the sidecar: ISO 8601 with a numeric offset, `2026-10-12T07:30:15+02:00`
/// (`### The sidecar` of `docs/PROTOCOL.md`, plan F55, F77).
///
/// `ISO8601DateFormatter` writes `Z` for a zero offset, which is London all winter. Python 3.9's
/// `datetime.fromisoformat`, the Mac's `/usr/bin/python3`, refuses `Z`, so it becomes `+00:00`.
public nonisolated enum SpokenAt {
    public static func string(_ d: Date, zone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        let s = f.string(from: d)
        if s.hasSuffix("Z") { return String(s.dropLast()) + "+00:00" }
        return s
    }
}

/// The header line of a text note: `yyyy-MM-dd HH:mm` in Europe/Paris with no offset, the form
/// `HEADER_TS` reads (`tools/header_ts.py`). The Mac reads
/// the header as Paris time, so the phone writes Paris time wherever it is (plan F80, A4).
public nonisolated enum HeaderTime {
    public static let zone = TimeZone(identifier: "Europe/Paris")!

    public static func string(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
