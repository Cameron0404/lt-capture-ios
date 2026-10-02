import Foundation
import Testing
@testable import LTCaptureCore

/// The receipt fixture, written here in code (no binary fixtures). Shaped like `record_captures`
/// writes it (as the reference Mac side writes it), with the Mac's own
/// `filed_as` words, plus an unknown key, an unknown status and one broken entry.
let receiptFixture = """
{
 "mac_seen_at": "2026-10-12T07:31:02+02:00",
 "schema_hint": "ignored",
 "captures": [
  {"name": "2026-10-12-070000-0001.m4a", "status": "waiting-audio-off",
   "filed_as": "not transcribed, audio intake is off", "first_seen_at": "2026-10-12T07:00:40+02:00", "at": "2026-10-12T07:00:40+02:00"},
  {"name": "2026-10-12-073015-4821.m4a", "capture_id": "OURS", "status": "filed",
   "filed_as": "Book the bike service as reminder",
   "first_seen_at": "2026-10-12T07:30:40+02:00", "at": "2026-10-12T07:31:02+02:00", "extra": 1},
  {"name": "2026-10-12-074500-1234.m4a", "capture_id": "SOMEONE-ELSE", "status": "filed", "filed_as": "not ours"},
  {"name": "2026-10-12-075000-0002.m4a", "capture_id": "OURS-2", "status": "archived-by-a-future-mac"},
  {"status": "filed"},
  {"name": "dictation-2026-10-12-080000-0003.txt", "status": "needs-cam", "filed_as": "kept, check the date"}
 ]
}
"""

struct ReceiptTests {
    let sentAt = Date(timeIntervalSince1970: 1_791_000_000)

    func receipt() throws -> Receipt { try Receipt.decode(Data(receiptFixture.utf8)) }

    func sentItem(stem: String = "2026-10-12-073015-4821", id: String = "OURS") -> OutboxItem {
        var s = OutboxState(captureID: id, createdAt: sentAt.addingTimeInterval(-60))
        s.sent_at = sentAt
        return OutboxItem(stem: stem, folder: URL(fileURLWithPath: "/nowhere/\(stem)"), state: s)
    }

    @Test func decodesLenientlyAndSkipsABrokenEntry() throws {
        let r = try receipt()
        #expect(r.mac_seen_at == "2026-10-12T07:31:02+02:00")
        #expect(r.captures.count == 5)
        #expect(r.captures.map(\.kind) == [.waitingAudioOff, .filed, .filed, .other, .needsCam])
        #expect(try Receipt.decode(Data("{}".utf8)).captures.isEmpty)
        #expect(throws: (any Error).self) { try Receipt.decode(Data("not json".utf8)) }
    }

    @Test func matchingByNameAndCaptureID() throws {
        let r = try receipt()
        // A waiting entry carries no capture_id, so the name alone matches.
        #expect(ReceiptMatcher.entry(name: "2026-10-12-070000-0001.m4a", captureID: "ANY", in: r)?.kind == .waitingAudioOff)
        // A filed entry with our id.
        #expect(ReceiptMatcher.entry(name: "2026-10-12-073015-4821.m4a", captureID: "OURS", in: r)?.filed_as
                == "Book the bike service as reminder")
        // Same name, another id: not ours.
        #expect(ReceiptMatcher.entry(name: "2026-10-12-074500-1234.m4a", captureID: "OURS", in: r) == nil)
        // Another name: not ours.
        #expect(ReceiptMatcher.entry(name: "2026-10-12-073015-4822.m4a", captureID: "OURS", in: r) == nil)
        // A text note has no id on either side.
        #expect(ReceiptMatcher.entry(name: "dictation-2026-10-12-080000-0003.txt", captureID: nil, in: r)?.kind == .needsCam)
    }

    // Every row of the status table in `plan.md` `### Status words shown to the owner`.

    @Test func rowsFromTheReceiptEntry() {
        let item = sentItem()
        func words(_ status: String, _ filedAs: String? = nil) -> String {
            let e = Receipt.Entry(name: item.audioName, capture_id: "OURS", status: status, filed_as: filedAs)
            return StatusResolver.status(item, entry: e, placement: .unknown, receiptState: .missing, now: sentAt).words
        }
        #expect(words("filed", "Call the dentist as reminder") == "filed: Call the dentist as reminder")
        #expect(words("needs-cam", "kept, over 10 min") == "filed, worth a look: kept, over 10 min")
        #expect(words("failed", "x") == "task failed (the Mac has the note)")
        #expect(words("waiting-audio-off", "not transcribed, audio intake is off") == "waiting, audio off")
        #expect(words("something-new") == "received")
    }

    @Test func rowsFromThePlaceAndTheClock() throws {
        let item = sentItem()
        let read = ReceiptState.read(try receipt())
        func words(_ p: Placement, after minutes: Double) -> String {
            StatusResolver.status(item, entry: nil, placement: p, receiptState: read, now: sentAt.addingTimeInterval(minutes * 60)).words
        }
        #expect(words(.inAudio, after: 2.9) == "sent")
        #expect(words(.inAudio, after: 3) == "not taken yet, is the Mac awake?")
        #expect(words(.inProcessed, after: 44.9) == "taken, not yet filed")
        #expect(words(.inProcessed, after: 45) == "not confirmed, check the vault")
        #expect(words(.unknown, after: 1) == "unknown, will check again")
        #expect(words(.absent, after: 1) == "unknown, will check again")
        #expect(StatusResolver.status(item, entry: nil, placement: .inAudio, receiptState: read, now: sentAt)
            .words(upload: "uploading") == "sent, uploading")
        #expect(CaptureStatus.notTakenYet.words(upload: "uploading") == "not taken yet, is the Mac awake?")
    }

    @Test func rowsFromTheReceiptFile() {
        let item = sentItem()
        func words(_ s: ReceiptState) -> String {
            StatusResolver.status(item, entry: nil, placement: .inAudio, receiptState: s, now: sentAt).words
        }
        #expect(words(.notPicked) == "receipt folder not picked")
        #expect(words(.missing) == "no receipt yet")
        #expect(words(.unreadable) == "unknown, will check again")
    }

    @Test func unsentAndHeldNotes() {
        var item = sentItem()
        item.state.sent_at = nil
        #expect(StatusResolver.status(item, entry: nil, placement: .absent, receiptState: .missing, now: sentAt) == .notSentYet)
        item.state.held_reason = HoldReason.nothingHeard.rawValue
        #expect(StatusResolver.status(item, entry: nil, placement: .absent, receiptState: .missing, now: sentAt).words == "nothing heard, discard?")
    }

    @Test func textNotesAreNeverFailedForLackOfAnEntry() throws {
        let read = ReceiptState.read(try receipt())
        #expect(StatusResolver.textStatus(sentAt: sentAt, entry: nil, receiptState: read, now: sentAt.addingTimeInterval(44 * 60)) == .sent)
        #expect(StatusResolver.textStatus(sentAt: sentAt, entry: nil, receiptState: read, now: sentAt.addingTimeInterval(45 * 60)) == .notConfirmed)
        #expect(StatusResolver.textStatus(sentAt: sentAt, entry: nil, receiptState: .notPicked, now: sentAt) == .receiptFolderNotPicked)
        let e = Receipt.Entry(name: "dictation-x.txt", status: "filed", filed_as: "Buy milk as task")
        #expect(StatusResolver.textStatus(sentAt: sentAt, entry: e, receiptState: read, now: sentAt) == .filed("Buy milk as task"))
    }

    @Test func aFailedEntryAfterFiledOffersNoResend() throws {
        // `record_captures` keeps one entry per name, so `failed` written after `filed` replaces it.
        let r = Receipt(mac_seen_at: nil, captures: [
            Receipt.Entry(name: "2026-10-12-073015-4821.m4a", capture_id: "OURS", status: "failed", filed_as: "Call the dentist as reminder"),
        ])
        let e = ReceiptMatcher.entry(name: "2026-10-12-073015-4821.m4a", captureID: "OURS", in: r)
        #expect(e?.kind == .failed)
        // Even if both listings say the file is gone, an entry means the Mac has the note.
        #expect(StatusResolver.offersResend(entry: e, decision: .send) == false)
        #expect(StatusResolver.offersResend(entry: nil, decision: .send) == true)
        #expect(StatusResolver.offersResend(entry: nil, decision: .unknown) == false)
        #expect(StatusResolver.offersResend(entry: nil, decision: .alreadyThere) == false)
    }

    @Test func readingTheReceipt() async throws {
        let out = tempFolder("receipt")
        let fs = LocalFileSystem()
        #expect(await ReceiptReader.load(fs: fs, outFolder: nil) == .notPicked)
        #expect(await ReceiptReader.load(fs: fs, outFolder: out) == .missing)
        try Data("{half".utf8).write(to: out.appendingPathComponent("captures.json"))
        #expect(await ReceiptReader.load(fs: fs, outFolder: out) == .unreadable)
        try Data(receiptFixture.utf8).write(to: out.appendingPathComponent("captures.json"))
        #expect(await ReceiptReader.load(fs: fs, outFolder: out) == .read(try receipt()))
    }

    @Test func aStuckReadTimesOut() async {
        let clock = ContinuousClock()
        let start = clock.now
        let state = await ReceiptReader.load(fs: StuckFileSystem(), outFolder: URL(fileURLWithPath: "/nowhere"), timeout: .milliseconds(200))
        #expect(state == .unreadable)
        #expect(clock.now - start < .seconds(5))
    }

    @MainActor
    @Test func theReceiptReadRunsOffTheMainThread() async throws {
        #expect(onMainThread())
        let out = tempFolder("receipt-thread")
        try Data(receiptFixture.utf8).write(to: out.appendingPathComponent("captures.json"))
        let fs = RecordingFileSystem()
        _ = await ReceiptReader.load(fs: fs, outFolder: out)
        #expect(fs.mainThreadCalls.isEmpty)
        // The recording file system does see main-thread calls, so the check can fail.
        _ = try await fs.read(out.appendingPathComponent("captures.json"), timeout: .seconds(1))
        #expect(fs.mainThreadCalls == ["read captures.json"])
    }

    @Test func uploadWords() {
        #expect(UploadState.words(isUbiquitous: true, uploaded: true, uploading: false, error: false) == "uploaded")
        #expect(UploadState.words(isUbiquitous: true, uploaded: false, uploading: true, error: false) == "uploading")
        #expect(UploadState.words(isUbiquitous: true, uploaded: false, uploading: false, error: false) == "waiting to upload")
        #expect(UploadState.words(isUbiquitous: true, uploaded: false, uploading: true, error: true) == "upload failed, iCloud will retry")
        #expect(UploadState.words(isUbiquitous: nil, uploaded: nil, uploading: nil, error: false) == "upload state unknown")
        #expect(UploadState.words(isUbiquitous: true, uploaded: nil, uploading: nil, error: false) == "upload state unknown")
        #expect(UploadState.words(isUbiquitous: false, uploaded: nil, uploading: nil, error: false) == "saved, not an iCloud folder")
    }
}
