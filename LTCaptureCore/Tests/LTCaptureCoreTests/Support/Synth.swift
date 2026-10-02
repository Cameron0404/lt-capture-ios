import AVFoundation
import AudioToolbox
import Foundation

/// Whether this process can reach an AAC encoder at all. Inside the agent sandbox the Audio
/// Component registrar is out of reach, so `AudioComponentCount` finds no component of any kind
/// and every AAC read or write fails with `fmt?` (found in build-2, 30 Sep). Tests that need the
/// codec are disabled then, and `EncoderTests.aacCodecIsReachable` fails with `marker`, which
/// `verify.sh` step 1 turns into NOT RUN (exit 3, never green).
nonisolated enum Codecs {
    static let marker = "LTCAP-NO-AAC-CODEC"

    static let aacReachable: Bool = {
        var d = AudioComponentDescription(componentType: kAudioEncoderComponentType, componentSubType: kAudioFormatMPEG4AAC,
                                          componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        return AudioComponentCount(&d) > 0
    }()
}

/// Synthetic PCM `.caf` files in the recorder's own format (16-bit, 24 kHz, mono), so no test
/// ever needs a microphone (plan rule 4).
nonisolated enum Synth {
    enum Segment {
        case silence(seconds: Double)
        /// A 220 Hz tone shaped like speech: syllables about 4 a second and a short pause every 2 s.
        case tone(seconds: Double)
        /// Quiet white noise from a fixed seed, so every run writes the same file.
        case noise(seconds: Double)
    }

    static let rate: Double = 24000

    static func caf(_ segments: [Segment], name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltcap-synth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".caf")
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 24000
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        var seed: UInt64 = 0x5EED
        var t: Int64 = 0
        for segment in segments {
            let (seconds, sample): (Double, (Int64) -> Float) = switch segment {
            case .silence(let s): (s, { _ in 0 })
            case .tone(let s): (s, { n in
                let x = Double(n) / rate
                let syllable = max(0, sin(2 * .pi * 4 * x))
                let pause = x.truncatingRemainder(dividingBy: 2) > 1.7 ? 0.0 : 1.0
                return Float(0.3 * syllable * pause * sin(2 * .pi * 220 * x))
            })
            case .noise(let s): (s, { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int64(seed >> 33) - (1 << 30)) / Float(1 << 30) * 0.05
            })
            }
            var left = Int64(seconds * rate)
            while left > 0 {
                let n = AVAudioFrameCount(min(Int64(chunk), left))
                let p = buffer.floatChannelData![0]
                for i in 0..<Int(n) { p[i] = sample(t + Int64(i)) }
                buffer.frameLength = n
                try file.write(from: buffer)
                t += Int64(n)
                left -= Int64(n)
            }
        }
        file.close()
        return url
    }
}
