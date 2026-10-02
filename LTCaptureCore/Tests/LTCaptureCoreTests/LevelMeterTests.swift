import Foundation
import Testing
@testable import LTCaptureCore

/// dBFS per 50 ms tick from a PCM file, the salvage path's input (plan `## Stage 3`, F75).
/// Files are written in the recorder's own PCM format by `Synth`, so no codec is needed.
struct LevelMeterTests {
    @Test func oneTickPerFiftyMilliseconds() throws {
        #expect(try LevelMeter.ticks(pcm: Synth.caf([.tone(seconds: 3)], name: "meter-3s"), every: 0.05).count == 60)
        // A last part under half a tick is dropped, one over half is kept.
        #expect(try LevelMeter.ticks(pcm: Synth.caf([.silence(seconds: 3.02)], name: "meter-302"), every: 0.05).count == 60)
        #expect(try LevelMeter.ticks(pcm: Synth.caf([.silence(seconds: 3.04)], name: "meter-304"), every: 0.05).count == 61)
    }

    @Test func digitalSilenceIsTheFloorNotInfinity() throws {
        let ticks = try LevelMeter.ticks(pcm: Synth.caf([.silence(seconds: 2)], name: "meter-silence"), every: 0.05)
        #expect(ticks.count == 40)
        #expect(ticks.allSatisfy { $0 == LevelMeter.silenceDB && $0.isFinite })
        #expect(LevelMeter.dBFS([Float]()) == LevelMeter.silenceDB)
        #expect(LevelMeter.dBFS([Float](repeating: 0, count: 1200)) == LevelMeter.silenceDB)
        #expect(LevelMeter.dBFS([Float.nan, 0.5]) == LevelMeter.silenceDB)
    }

    @Test func knownLevels() {
        func sine(_ amp: Float) -> [Float] { (0..<2400).map { amp * sin(2 * .pi * 220 * Float($0) / 24000) } }
        // A sine's RMS is its amplitude over root 2, so full scale reads -3.01 dBFS.
        #expect(abs(LevelMeter.dBFS(sine(1)) - -3.01) < 0.05)
        #expect(abs(LevelMeter.dBFS(sine(0.5)) - -9.03) < 0.05)
        #expect(LevelMeter.dBFS([Float](repeating: 1, count: 100)) == 0)
        #expect(LevelMeter.dBFS([Float](repeating: 4, count: 100)) == 0)
    }

    @Test func toneIsLouderThanNoiseIsLouderThanSilence() throws {
        let url = try Synth.caf([.tone(seconds: 1), .noise(seconds: 1), .silence(seconds: 1)], name: "meter-mix")
        let t = try LevelMeter.ticks(pcm: url, every: 0.05)
        #expect(t.count == 60)
        let tone = t[0..<20].max()!, noise = t[20..<40].reduce(0, +) / 20, silence = t[40..<60].max()!
        #expect(tone > -20)
        // Uniform noise of amplitude 0.05 has RMS 0.05 over root 3, about -30.8 dBFS.
        #expect(abs(noise - -30.8) < 1.5)
        #expect(silence == LevelMeter.silenceDB)
    }

    @Test func refusesABadIntervalAndAMissingFile() {
        #expect(throws: LevelMeterError.badInterval) {
            try LevelMeter.ticks(pcm: URL(fileURLWithPath: "/nonexistent.caf"), every: 0)
        }
        #expect(throws: LevelMeterError.self) {
            try LevelMeter.ticks(pcm: URL(fileURLWithPath: "/nonexistent.caf"), every: 0.05)
        }
    }
}
