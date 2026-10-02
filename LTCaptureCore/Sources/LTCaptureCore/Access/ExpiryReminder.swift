import Foundation

/// The in-app warning before the signing profile lapses (plan F8, F67). A free Personal Team
/// profile lasts 7 days, a paid one a year, and the app will not open once it has lapsed.
///
/// The date is the `ExpirationDate` of the app's `embedded.mobileprovision`: a signed blob with an
/// XML plist inside, read between `<?xml` and `</plist>`. With no readable profile it falls back
/// to the executable's date plus 7 days, the free team's length.
public nonisolated enum ExpiryReminder {
    /// The banner shows from this long before expiry, which is from day 6 of a 7-day profile.
    public static let warnBefore: TimeInterval = 36 * 3600
    public static let freeProfileLength: TimeInterval = 7 * 24 * 3600

    public static func expiry(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// The profile's date when there is one, else the executable's date plus 7 days.
    public static func expiry(profile: Data?, executableDate: Date?) -> Date? {
        if let profile, let d = expiry(fromProfile: profile) { return d }
        return executableDate.map { $0.addingTimeInterval(freeProfileLength) }
    }

    public static func showBanner(expiry: Date?, now: Date) -> Bool {
        guard let expiry else { return false }
        return now >= expiry.addingTimeInterval(-warnBefore)
    }
}
