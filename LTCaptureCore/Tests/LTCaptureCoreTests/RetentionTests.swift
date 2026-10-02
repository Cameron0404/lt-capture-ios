import Foundation
import Testing
@testable import LTCaptureCore

/// One test per status and words pair in the retention rule, and 14 days otherwise.
/// The words are the ones the reference Mac side writes.
struct RetentionTests {
    let sentAt = Date(timeIntervalSince1970: 1_791_000_000)
    let day: TimeInterval = 24 * 3600

    var item: OutboxItem {
        var s = OutboxState(captureID: "OURS", createdAt: sentAt)
        s.sent_at = sentAt
        return OutboxItem(stem: "2026-10-12-073015-4821", folder: URL(fileURLWithPath: "/nowhere"), state: s)
    }

    func canDelete(_ status: String, _ filedAs: String?, after days: Double = 0) -> Bool {
        let e = Receipt.Entry(name: item.audioName, capture_id: "OURS", status: status, filed_as: filedAs)
        return Retention.canDelete(item, entry: e, now: sentAt.addingTimeInterval(days * day))
    }

    // Before any check: keep the full 14 days.

    @Test func waitingAudioOffIsKept() {
        #expect(!canDelete("waiting-audio-off", "not transcribed, audio intake is off"))
        #expect(canDelete("waiting-audio-off", "not transcribed, audio intake is off", after: 14))
    }

    @Test func nameMismatchIsKept() {
        #expect(!canDelete("needs-cam", "kept, name mismatch", after: 13.9))
    }

    @Test func notSelfOnlyIsKept() {
        #expect(!canDelete("needs-cam", "kept, not self only", after: 13.9))
    }

    // After the checks.

    @Test func overTenMinutesEndsEarly() {
        #expect(canDelete("needs-cam", "kept, over 10 min"))
    }

    @Test func unclearAudioEndsEarly() {
        #expect(canDelete("needs-cam", "kept, unclear audio"))
    }

    @Test func filedEndsEarly() {
        #expect(canDelete("filed", "Call the dentist as reminder"))
    }

    @Test func failedIsKept() {
        #expect(!canDelete("failed", "Call the dentist as reminder", after: 13.9))
        #expect(canDelete("failed", "Call the dentist as reminder", after: 14))
    }

    @Test func otherNeedsCamWordsAndUnknownStatusesAreKept() {
        #expect(!canDelete("needs-cam", "kept, something new", after: 13.9))
        #expect(!canDelete("needs-cam", nil, after: 13.9))
        #expect(!canDelete("received-by-a-future-mac", nil, after: 13.9))
    }

    @Test func noEntryKeepsFourteenDays() {
        #expect(!Retention.canDelete(item, entry: nil, now: sentAt.addingTimeInterval(14 * day - 1)))
        #expect(Retention.canDelete(item, entry: nil, now: sentAt.addingTimeInterval(14 * day)))
    }

    @Test func aNoteNeverSentIsNeverDeleted() {
        var unsent = item
        unsent.state.sent_at = nil
        let filed = Receipt.Entry(name: unsent.audioName, status: "filed", filed_as: "x")
        #expect(!Retention.canDelete(unsent, entry: filed, now: sentAt.addingTimeInterval(365 * day)))
    }
}
