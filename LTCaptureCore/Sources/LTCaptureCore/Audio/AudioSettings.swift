import AVFoundation

/// How a note is recorded and encoded (plan `### Data`, F19, F22, F59, F72, target.md A2).
///
/// The recorder writes linear PCM to a `.caf`, then the encoder turns it into AAC-LC in an `.m4a`.
/// The strategy is Variable Constrained: constant bit rate fails the Mac's check on silence (F19),
/// and plain Variable ignores the bit rate key, so at `AVAudioQuality.high` a 60 s speech-like tone
/// came out at 21.4 kbps, under the 24 kbps floor (F72, verify run of 30 Sep). Variable Constrained
/// stays variable, passes `m4acheck.py` on silence, and follows the bit rate: 48 kbps nominal gave
/// 32.7 kbps on that tone (the 24 kHz, 48 kbps listening setting chosen in testing).
public nonisolated struct AudioSettings: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    /// `record(forDuration:)` stops here, under the protocol's 600 s cap measured to 0.1 s (F22).
    public var recordSeconds: Double
    /// The encoder never writes more frames than this many seconds, whatever the `.caf` holds.
    public var encodeCapSeconds: Double
    /// The longest note the Mac takes (`## Audio notes` of `docs/PROTOCOL.md`).
    public var protocolCapSeconds: Double
    /// The nominal AAC bit rate, in bits per second, under the Variable Constrained strategy.
    public var bitRate: Int

    public static let standard = AudioSettings(sampleRate: 24000, channels: 1, recordSeconds: 599.0,
                                               encodeCapSeconds: 599.5, protocolCapSeconds: 600.0,
                                               bitRate: 48000)

    /// For `AVAudioRecorder`: 16-bit linear PCM, metering is switched on by the recorder itself.
    public var recorderSettings: [String: any Sendable] {
        [AVFormatIDKey: Int(kAudioFormatLinearPCM),
         AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false,
         AVLinearPCMIsBigEndianKey: false]
    }

    /// For the `AVAudioFile` the encoder writes. `rate` is the source file's own rate, because
    /// `AVAudioFile` does not resample on write and the phone may not honour 24 kHz (plan, Risks).
    public func aacSettings(rate: Double) -> [String: any Sendable] {
        [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
         AVSampleRateKey: rate,
         AVNumberOfChannelsKey: channels,
         AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained,
         AVEncoderBitRateKey: bitRate,
         AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    }
}
