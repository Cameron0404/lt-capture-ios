import AVFoundation

public nonisolated enum LevelMeterError: Error, Equatable {
    case badInterval
    case unreadable(String)
}

/// Levels in dBFS, the unit `AVAudioRecorder.averagePower(forChannel:)` reports, so the silence
/// detector reads the same numbers live and offline (plan `## Stage 3`, F75).
///
/// Live, the app feeds the detector one metering value every 50 ms. Offline, `ticks(pcm:every:)`
/// measures a salvaged `.caf` the same way, which is how launch decides whether a leftover note
/// heard any voice before it is encoded and sent.
public nonisolated enum LevelMeter {
    /// The floor for digital silence, the same as the recorder's own. `log10(0)` is `-inf`, and
    /// `-inf` minus a floor is `nan`, so no value below this ever reaches the detector.
    public static let silenceDB: Float = -160

    /// The RMS level of `samples` in dBFS, clamped to `silenceDB ... 0`.
    public static func dBFS<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return silenceDB }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms.isFinite, rms > 0 else { return silenceDB }
        return Float(min(0, max(Double(silenceDB), 20 * log10(rms))))
    }

    /// One dBFS value per `every` seconds of the file. A last part shorter than half a tick is
    /// dropped, so a 3 s file gives 60 ticks at 50 ms.
    public static func ticks(pcm: URL, every: TimeInterval) throws -> [Float] {
        guard every > 0 else { throw LevelMeterError.badInterval }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: pcm, commonFormat: .pcmFormatFloat32, interleaved: false) } catch {
            throw LevelMeterError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let perTick = max(1, Int((every * format.sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(perTick)) else {
            throw LevelMeterError.badInterval
        }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / perTick + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(perTick))
            let n = Int(buffer.frameLength)
            if n == 0 || n * 2 < perTick { break }
            // Channel 0 only: the recorder is mono (`AudioSettings.standard`).
            out.append(dBFS(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)))
        }
        return out
    }
}
