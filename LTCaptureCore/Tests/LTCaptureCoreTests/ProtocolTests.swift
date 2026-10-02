import Foundation
import Testing
@testable import LTCaptureCore

/// Names, `spoken_at`, the sidecar and the text body (plan `## Stage 2`, F24, F55, F77, F80, F82, F83).
struct ProtocolTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    let london = TimeZone(identifier: "Europe/London")!

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func namesAcrossNewYearInParis() {
        #expect(CaptureNaming.stem(start: date("2026-12-31T23:59:59+01:00"), zone: paris, suffix: 4821)
                == "2026-12-31-235959-4821")
        #expect(CaptureNaming.stem(start: date("2027-01-01T00:00:00+01:00"), zone: paris, suffix: 7)
                == "2027-01-01-000000-0007")
        #expect(CaptureNaming.textName(start: date("2027-01-01T00:00:00+01:00"), zone: paris, suffix: 12)
                == "dictation-2027-01-01-000000-0012.txt")
    }

    @Test func namesIgnoreABuddhistCalendar() {
        let d = date("2026-12-31T23:59:59+01:00")
        // A formatter left to a Thai phone's calendar writes the Buddhist year, which the Mac would misfile.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "th_TH@calendar=buddhist")
        naive.calendar = Calendar(identifier: .buddhist)
        naive.timeZone = paris
        naive.dateFormat = CaptureNaming.datePattern
        #expect(naive.string(from: d).hasPrefix("2569"))
        #expect(CaptureNaming.stem(start: d, zone: paris, suffix: 0) == "2026-12-31-235959-0000")
    }

    @Test func suffixIsAlwaysFourDigits() {
        let d = date("2026-10-12T07:30:15+02:00")
        for _ in 0..<200 {
            let stem = CaptureNaming.stem(start: d, zone: paris, suffix: CaptureNaming.randomSuffix())
            #expect(stem.range(of: #"^2026-10-12-073015-\d{4}$"#, options: .regularExpression) != nil)
        }
        #expect(CaptureNaming.stem(start: d, zone: paris, suffix: 10000 + 42).hasSuffix("-0042"))
    }

    @Test func spokenAtNeverEndsInZ() {
        let utc = SpokenAt.string(date("2026-10-12T05:30:15Z"), zone: TimeZone(identifier: "UTC")!)
        let summer = SpokenAt.string(date("2026-07-15T10:00:00Z"), zone: paris)
        let winter = SpokenAt.string(date("2027-01-03T09:15:00Z"), zone: london)
        #expect(utc == "2026-10-12T05:30:15+00:00")
        #expect(summer == "2026-07-15T12:00:00+02:00")
        #expect(winter == "2027-01-03T09:15:00+00:00")
        for s in [utc, summer, winter] { #expect(!s.hasSuffix("Z")) }
    }

    @Test func sidecarKeysAndIntegerBytes() throws {
        let plain = Sidecar(audioFile: "2026-10-12-073015-4821.m4a", captureID: UUID().uuidString,
                            spokenAt: "2026-10-12T07:30:15+02:00", bytes: 48213, durationSeconds: 312.39999)
        let json = try plain.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["audio_file", "capture_id", "spoken_at", "bytes", "self_only", "duration_s"])
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains(#""bytes":48213,"#))
        #expect(text.contains(#""duration_s":312.4,"#))
        #expect(object["self_only"] as? Bool == true)

        let marked = Sidecar(audioFile: "a.m4a", captureID: "x", spokenAt: "2026-10-12T07:30:15+02:00",
                             bytes: 1, test: true)
        let keys = try #require(try JSONSerialization.jsonObject(with: marked.encoded()) as? [String: Any]).keys
        #expect(Set(keys) == ["audio_file", "capture_id", "spoken_at", "bytes", "self_only", "test"])
        #expect(Set(keys).isSubset(of: Sidecar.keys))
        #expect(try JSONDecoder().decode(Sidecar.self, from: json) == plain)

        for (name, zone) in [("utc", TimeZone(identifier: "UTC")!), ("london", london), ("paris", paris)] {
            let s = Sidecar(audioFile: "sidecar-\(name).m4a", captureID: UUID().uuidString,
                            spokenAt: SpokenAt.string(date("2027-01-03T09:15:00Z"), zone: zone), bytes: 48213)
            let file = "sidecar-\(name).json"
            try s.encoded().write(to: Artefacts.url(file))
            try Artefacts.record(file, kind: "json", expect: "pass", test: "sidecarKeysAndIntegerBytes")
        }
    }

    /// Copied from the reference Mac side's header pattern (`tools/header_ts.py`).
    /// `scripts/check_artefacts.sh` also reads the live pattern from that file, so a change there is caught.
    static let headerTS = #"^\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::\d{2})?\s*$"#

    @Test func textBodyHeaderIsParisTimeWhereverThePhoneIs() throws {
        let instant = date("2026-10-12T05:30:00Z")   // 06:30 London, 01:30 New York, 07:30 Paris
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for (name, zone) in [("london", london), ("newyork", TimeZone(identifier: "America/New_York")!)] {
            NSTimeZone.default = zone
            let body = try #require(TextNote.body("  buy milk\n", at: instant))
            let lines = body.components(separatedBy: "\n")
            #expect(lines[0] == "2026-10-12 07:30")
            #expect(lines[0].range(of: Self.headerTS, options: .regularExpression) != nil)
            #expect(lines[1] == "")
            #expect(lines[2] == "buy milk")
            let file = "text-\(name).txt"
            try Data(body.utf8).write(to: Artefacts.url(file))
            try Artefacts.record(file, kind: "txt", expect: "pass", test: "textBodyHeaderIsParisTimeWhereverThePhoneIs")
        }
    }

    @Test func emptyTextIsNeverSent() {
        #expect(TextNote.body("", at: Date()) == nil)
        #expect(TextNote.body(" \n\t ", at: Date()) == nil)
    }
}
