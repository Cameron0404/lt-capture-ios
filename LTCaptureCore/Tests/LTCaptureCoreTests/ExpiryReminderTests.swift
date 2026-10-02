import Foundation
import Testing
@testable import LTCaptureCore

/// The day-6 banner (plan F8, F67), from a profile-shaped blob made here in code.
struct ExpiryReminderTests {
    let installed = Date(timeIntervalSince1970: 1_791_000_000)
    let day: TimeInterval = 24 * 3600

    /// Signed-blob bytes around an XML plist, like `embedded.mobileprovision`.
    func profile(expiring: Date) throws -> Data {
        let plist: [String: Any] = ["AppIDName": "LT Capture", "ExpirationDate": expiring, "TeamName": "Personal Team"]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return Data([0x30, 0x82, 0x3a, 0x10, 0x06, 0x09]) + xml + Data([0xa0, 0x82, 0x0b, 0x00, 0x3c, 0x2f])
    }

    @Test func readsTheExpirationDateFromAProfile() throws {
        let expiry = installed.addingTimeInterval(7 * day)
        #expect(ExpiryReminder.expiry(fromProfile: try profile(expiring: expiry)) == expiry)
        #expect(ExpiryReminder.expiry(fromProfile: Data("no plist here".utf8)) == nil)
        #expect(ExpiryReminder.expiry(fromProfile: Data("<?xml broken".utf8)) == nil)
    }

    @Test func theBannerShowsFromDaySixAndNotBefore() throws {
        let expiry = ExpiryReminder.expiry(profile: try profile(expiring: installed.addingTimeInterval(7 * day)), executableDate: nil)
        func shows(_ days: Double) -> Bool { ExpiryReminder.showBanner(expiry: expiry, now: installed.addingTimeInterval(days * day)) }
        #expect(!shows(0))
        #expect(!shows(5))
        #expect(!shows(5.49))
        #expect(shows(5.5))   // 36 h before expiry, inside day 6
        #expect(shows(6))
        #expect(shows(7))
        #expect(shows(8))
    }

    @Test func aMissingProfileFallsBackToTheExecutableDatePlusSevenDays() {
        let expiry = ExpiryReminder.expiry(profile: nil, executableDate: installed)
        #expect(expiry == installed.addingTimeInterval(7 * day))
        #expect(ExpiryReminder.expiry(profile: Data("garbage".utf8), executableDate: installed) == expiry)
        #expect(!ExpiryReminder.showBanner(expiry: expiry, now: installed.addingTimeInterval(5 * day)))
        #expect(ExpiryReminder.showBanner(expiry: expiry, now: installed.addingTimeInterval(6 * day)))
        #expect(!ExpiryReminder.showBanner(expiry: nil, now: installed))
    }

    @Test func aPaidProfileShowsNoBannerForMonths() throws {
        let expiry = ExpiryReminder.expiry(profile: try profile(expiring: installed.addingTimeInterval(365 * day)), executableDate: installed)
        #expect(!ExpiryReminder.showBanner(expiry: expiry, now: installed.addingTimeInterval(300 * day)))
    }
}
