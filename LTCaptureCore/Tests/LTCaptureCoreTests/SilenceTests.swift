import Foundation
import Testing
@testable import LTCaptureCore

/// Level traces in dB, one value per 50 ms tick, shaped like what the system recorder meters.
/// Speech is loud syllables with a gap at the room's level every fourth tick, the way words have
/// gaps. Every trace is fixed, so each run gives the same answer.
nonisolated enum Trace {
    static let tick = SilenceConfig.standard.tick

    static func count(_ seconds: Double) -> Int { Int((seconds / tick).rounded()) }

    static func voice(_ seconds: Double, room: Float = -60, loud: Float = -20) -> [Float] {
        (0..<count(seconds)).map { i in i % 4 == 3 ? room : loud - Float(i % 3) * 3 }
    }

    /// A steady sound (room, fan, or digital silence at -160) wobbling by up to `wobble` dB.
    static func steady(_ seconds: Double, at level: Float, wobble: Float = 1) -> [Float] {
        (0..<count(seconds)).map { i in level + wobble * Float(i % 5 - 2) / 2 }
    }

    /// Several people talking at once: levels from -45 to -20 dB from a fixed seed.
    static func babble(_ seconds: Double) -> [Float] {
        var seed: UInt64 = 0xBABB1E
        return (0..<count(seconds)).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return -45 + Float(seed >> 40) / Float(1 << 24) * 25
        }
    }
}

/// The silence detector against the plan's traces (`### Stop policy`, `## Stage 3`, F41, F66, F73, F75).
struct SilenceTests {
    func decide(_ ticks: [Float], _ config: SilenceConfig = .standard) -> SilenceDetector.Decision {
        SilenceDetector.decide(ticks, config: config)
    }

    /// The time of the last voiced tick in a trace, found by the detector itself.
    func lastVoice(_ ticks: [Float]) -> TimeInterval {
        var d = SilenceDetector(SilenceConfig(enabled: false))
        for (i, dB) in ticks.enumerated() { _ = d.feed(dB: dB, at: Double(i + 1) * Trace.tick, foreground: false) }
        return d.lastVoicedAt ?? 0
    }

    @Test func pausesOfTenAndEighteenSecondsDoNotStop() {
        let trace = Trace.voice(8) + Trace.steady(10, at: -60) + Trace.voice(8) + Trace.steady(18, at: -60) + Trace.voice(5)
        let d = decide(trace)
        #expect(d.stop == nil)
        #expect(d.heardVoice)
    }

    @Test func aTwentyOneSecondPauseStops() {
        let speech = Trace.voice(8)
        let d = decide(speech + Trace.steady(21, at: -60))
        #expect(d.stop == .silence)
        #expect(abs(d.stoppedAt! - lastVoice(speech) - 20) < 0.06)
    }

    @Test func aSteadyFanAfterSpeechStopsAtTwentySecondsAndWarnsAtFifteen() {
        let speech = Trace.voice(10, room: -45)
        let trace = speech + Trace.steady(40, at: -45)
        var d = SilenceDetector()
        var warnAt: TimeInterval?, stopAt: TimeInterval?
        for (i, dB) in trace.enumerated() {
            let t = Double(i + 1) * Trace.tick
            switch d.feed(dB: dB, at: t, foreground: true) {
            case .warn?: #expect(warnAt == nil); warnAt = t
            case .stop(let r)?: #expect(r == .silence); stopAt = t
            case nil: break
            }
            if stopAt != nil { break }
        }
        let last = lastVoice(speech)
        #expect(abs(warnAt! - last - 15) < 0.06)
        #expect(abs(stopAt! - last - 20) < 0.06)
    }

    @Test func twoMinutesOfBabbleDoesNotStop() {
        let d = decide(Trace.voice(6) + Trace.babble(120))
        #expect(d.stop == nil)
    }

    @Test func speechInsideTheFirstFiveSecondsDoesNotArm() {
        // 4.5 s of speech is over 3 s voiced, but all of it is before 5 s.
        var d = SilenceDetector()
        let early = Trace.voice(4.5)
        for (i, dB) in early.enumerated() { _ = d.feed(dB: dB, at: Double(i + 1) * Trace.tick, foreground: true) }
        #expect(d.voicedSeconds >= 3)
        #expect(!d.armed)
        let r = decide(early + Trace.steady(30, at: -60))
        #expect(r.stop == .unarmedQuiet)
        #expect(abs(r.stoppedAt! - lastVoice(early) - 10) < 0.06)
        // The same speech running past 5 s arms, so the note waits the full 20 s.
        let longer = Trace.voice(6)
        let armed = decide(longer + Trace.steady(30, at: -60))
        #expect(armed.stop == .silence)
        #expect(abs(armed.stoppedAt! - lastVoice(longer) - 20) < 0.06)
    }

    @Test func aFanStartingMidNoteBecomesTheFloorAndStops() {
        // Quiet room during speech, then a fan 25 dB louder that never stops. It counts as voice
        // until the floor has risen under it, 15 s at 1 dB a second, and then the 20 s run.
        let speech = Trace.voice(10, room: -70)
        let d = decide(speech + Trace.steady(90, at: -45, wobble: 0))
        #expect(d.stop == .silence)
        let afterSpeech = d.stoppedAt! - lastVoice(speech)
        #expect(afterSpeech >= 20 && afterSpeech <= 40, "stopped \(afterSpeech) s after the speech")
    }

    @Test func aThirtyDecibelStepDownKeepsGoingThenStops() {
        // The phone goes into a pocket: speech and room both drop 30 dB, the floor follows at once.
        let before = Trace.voice(10, room: -50, loud: -20)
        let after = Trace.voice(40, room: -80, loud: -50)
        #expect(decide(before + after).stop == nil)
        let d = decide(before + after + Trace.steady(21, at: -80))
        #expect(d.stop == .silence)
        #expect(abs(d.stoppedAt! - lastVoice(before + after) - 20) < 0.06)
    }

    @Test func theToggleOffNeverStops() {
        let off = SilenceConfig(enabled: false)
        #expect(decide(Trace.steady(120, at: LevelMeter.silenceDB, wobble: 0), off).stop == nil)
        #expect(decide(Trace.voice(8) + Trace.steady(120, at: -60), off).stop == nil)
        #expect(decide(Trace.voice(2) + Trace.steady(120, at: -50), off).stop == nil)
    }

    @Test func aSilentStartStopsAtThirtySecondsAsNothingHeard() {
        let d = decide(Trace.steady(40, at: LevelMeter.silenceDB, wobble: 0))
        #expect(d.stop == .nothingHeard)
        #expect(abs(d.stoppedAt! - 30) < 0.06)
        #expect(!d.heardVoice)
        // A room with only its own hum is nothing heard too.
        #expect(decide(Trace.steady(40, at: -52, wobble: 2)).stop == .nothingHeard)
    }

    @Test func twoSecondsVoiceThenRoomNoise() {
        let speech = Trace.voice(2, room: -50)
        let d = decide(speech + Trace.steady(60, at: -50, wobble: 2))
        #expect(d.stop == .unarmedQuiet)
        #expect(d.stoppedAt! - 2 <= 15)
    }

    @Test func noWarningInTheBackgroundButTheStopStillComes() {
        let trace = Trace.voice(10) + Trace.steady(30, at: -60)
        var d = SilenceDetector()
        var events: [SilenceEvent] = []
        for (i, dB) in trace.enumerated() {
            if let e = d.feed(dB: dB, at: Double(i + 1) * Trace.tick, foreground: false) { events.append(e) }
        }
        #expect(events == [.stop(.silence)])
        #expect(SilenceDetector.decide(trace, foreground: true).warnings == 1)
    }

    @Test func nothingAfterTheStopAndNoNaN() {
        var d = SilenceDetector()
        #expect(d.feed(dB: .nan, at: 0.05, foreground: true) == nil)
        #expect(d.feed(dB: -.infinity, at: 0.1, foreground: true) == nil)
        #expect(d.floorDB == LevelMeter.silenceDB)
        var t = 0.1
        var stop: SilenceEvent?
        while stop == nil { t += 0.05; stop = d.feed(dB: -160, at: t, foreground: true) }
        #expect(stop == .stop(.nothingHeard))
        #expect(d.feed(dB: -10, at: t + 0.05, foreground: true) == nil)
        #expect(d.stopped == .nothingHeard)
    }

    /// The salvage path: levels measured offline from a file decide the same as the live trace (F75).
    @Test func offlineLevelsDecideLikeTheTrace() throws {
        let file = try Synth.caf([.tone(seconds: 10), .silence(seconds: 25)], name: "salvage-voice")
        let offline = decide(try LevelMeter.ticks(pcm: file, every: Trace.tick))
        let live = decide(Trace.voice(10, room: LevelMeter.silenceDB) + Trace.steady(25, at: LevelMeter.silenceDB, wobble: 0))
        #expect(offline.stop == .silence && live.stop == .silence)
        #expect(offline.heardVoice && live.heardVoice)
        #expect(abs(offline.stoppedAt! - live.stoppedAt!) < 0.5, "offline \(offline.stoppedAt!) live \(live.stoppedAt!)")

        let quiet = try Synth.caf([.silence(seconds: 35)], name: "salvage-silent")
        let q = decide(try LevelMeter.ticks(pcm: quiet, every: Trace.tick))
        #expect(q.stop == .nothingHeard && !q.heardVoice)
        #expect(q == decide(Trace.steady(35, at: LevelMeter.silenceDB, wobble: 0)))
    }
}
