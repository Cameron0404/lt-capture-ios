import Foundation
import Testing
@testable import LTCaptureCore

/// PCM to AAC with the settings the app uses (plan `## Stage 2`, F19, F22, F64, F72).
/// Every file is handed to `scripts/check_artefacts.sh`, which runs the Mac's `m4acheck.py` on it.
@MainActor
struct EncoderTests {
    func encode(_ segments: [Synth.Segment], name: String) async throws -> (URL, EncodeResult) {
        let caf = try Synth.caf(segments, name: name)
        let out = Artefacts.url(name + ".m4a")
        let result = try await Encoder.encode(caf: caf, to: out, settings: .standard)
        return (out, result)
    }

    /// Fails, never skips, when the codec is out of reach, so a run without it is never green.
    @Test func aacCodecIsReachable() {
        #expect(Codecs.aacReachable, "\(Codecs.marker): no AAC encoder in this process, so the encode tests could not run")
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func pureSilenceEncodes() async throws {
        let (out, r) = try await encode([.silence(seconds: 3)], name: "silence-3s")
        #expect(abs(r.durationSeconds - 3) < 0.1)
        #expect(r.bytes == (try Artefacts.size(out)))
        try Artefacts.record("silence-3s.m4a", kind: "m4a", expect: "pass", test: "pureSilenceEncodes",
                             bytes: r.bytes, durationMin: 2.9, durationMax: 3.1)
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func silentLeadInThenToneEncodes() async throws {
        let (_, r) = try await encode([.silence(seconds: 2), .tone(seconds: 5)], name: "leadin-2s-tone-5s")
        #expect(abs(r.durationSeconds - 7) < 0.1)
        try Artefacts.record("leadin-2s-tone-5s.m4a", kind: "m4a", expect: "pass", test: "silentLeadInThenToneEncodes",
                             bytes: r.bytes, durationMin: 6.9, durationMax: 7.1)
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func noiseEncodes() async throws {
        let (_, r) = try await encode([.noise(seconds: 4)], name: "noise-4s")
        #expect(abs(r.durationSeconds - 4) < 0.1)
        try Artefacts.record("noise-4s.m4a", kind: "m4a", expect: "pass", test: "noiseEncodes",
                             bytes: r.bytes, durationMin: 3.9, durationMax: 4.1)
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func overlongSourceIsCutUnderTheCap() async throws {
        let (_, r) = try await encode([.tone(seconds: 605)], name: "tone-605s")
        #expect(r.framesWritten == Int64(599.5 * 24000))
        #expect(r.durationSeconds >= 599.0 && r.durationSeconds <= 600.0)
        try Artefacts.record("tone-605s.m4a", kind: "m4a", expect: "pass", test: "overlongSourceIsCutUnderTheCap",
                             bytes: r.bytes, durationMin: 599.0, durationMax: 600.0)
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func sixtySecondsIsTheExpectedSize() async throws {
        let (_, r) = try await encode([.tone(seconds: 60)], name: "tone-60s")
        // 24 to 64 kbps under Variable Constrained at 48 kbps nominal (F72).
        #expect(r.bytes >= 180_000 && r.bytes <= 480_000, "60 s encoded to \(r.bytes) bytes, \(r.kbps) kbps")
        try Artefacts.record("tone-60s.m4a", kind: "m4a", expect: "pass", test: "sixtySecondsIsTheExpectedSize",
                             bytes: r.bytes, durationMin: 59.9, durationMax: 60.1, kbps: r.kbps)
        // The sidecar the app would write beside it, for the Mac's JSON checks.
        let sidecar = Sidecar(audioFile: "tone-60s.m4a", captureID: UUID().uuidString,
                              spokenAt: SpokenAt.string(Date(), zone: TimeZone(identifier: "Europe/Paris")!),
                              bytes: r.bytes, durationSeconds: r.durationSeconds)
        try sidecar.encoded().write(to: Artefacts.url("tone-60s.json"))
        try Artefacts.record("tone-60s.json", kind: "json", expect: "pass", test: "sixtySecondsIsTheExpectedSize")
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func encodeRunsOffTheMainThread() async throws {
        #expect(onMainThread())
        let (_, r) = try await encode([.tone(seconds: 1)], name: "tone-1s-thread")
        #expect(r.ranOnMainThread == false)
    }
}
