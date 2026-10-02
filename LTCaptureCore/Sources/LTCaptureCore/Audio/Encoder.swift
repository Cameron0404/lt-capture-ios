import AVFoundation

/// What one encode produced.
public nonisolated struct EncodeResult: Sendable, Equatable {
    public var info: M4AInfo
    /// Source frames written, never more than `encodeCapSeconds` of them (F22).
    public var framesWritten: Int64
    /// Whether the encode ran on the main thread. Always false: it is `@concurrent` (F64).
    public var ranOnMainThread: Bool

    public var bytes: Int { info.bytes }
    public var durationSeconds: Double { info.durationSeconds }
    /// The average bit rate in kilobits per second, recorded by the host tests (F72).
    public var kbps: Double { info.durationSeconds > 0 ? Double(info.bytes) * 8 / info.durationSeconds / 1000 : 0 }
}

public nonisolated enum EncoderError: Error, Equatable {
    case notMono(Int)
    case emptySource
}

/// PCM `.caf` to AAC `.m4a` with `AVAudioFile`, then `close()` and `M4AValidator` (plan A2, F65).
public nonisolated enum Encoder {
    @concurrent
    public static func encode(caf: URL, to out: URL, settings: AudioSettings) async throws -> EncodeResult {
        let offMain = !onMainThread()
        let (writer, frames) = try write(caf: caf, to: out, settings: settings)
        writer.close()
        let info = try M4AValidator.validate(out, capSeconds: settings.protocolCapSeconds)
        return EncodeResult(info: info, framesWritten: frames, ranOnMainThread: !offMain)
    }

    /// Writes every frame but does not close the file, so the `moov` box is not there yet. The
    /// caller must close it. Internal so the host test can prove an unclosed file is refused (F65).
    static func write(caf: URL, to out: URL, settings: AudioSettings) throws -> (AVAudioFile, Int64) {
        let input = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard Int(format.channelCount) == settings.channels else { throw EncoderError.notMono(Int(format.channelCount)) }
        guard input.length > 0 else { throw EncoderError.emptySource }

        let writer = try AVAudioFile(forWriting: out, settings: settings.aacSettings(rate: format.sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let maxFrames = Int64(settings.encodeCapSeconds * format.sampleRate)
        let chunk: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw EncoderError.emptySource }
        var written: Int64 = 0
        // Stop on framePosition >= length (`AVAudioFile.h:137`), not on a read error.
        while input.framePosition < input.length && written < maxFrames {
            let want = AVAudioFrameCount(min(Int64(chunk), maxFrames - written))
            try input.read(into: buffer, frameCount: want)
            if buffer.frameLength == 0 { break }
            try writer.write(from: buffer)
            written += Int64(buffer.frameLength)
        }
        return (writer, written)
    }
}
