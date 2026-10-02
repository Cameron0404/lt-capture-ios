import AVFoundation

/// What a valid `.m4a` measured.
public nonisolated struct M4AInfo: Sendable, Equatable {
    public var bytes: Int
    public var frames: Int64
    public var sampleRate: Double
    public var durationSeconds: Double
}

public nonisolated enum M4AError: Error, Equatable {
    case unreadable(String)
    case truncated(String)
    case missing(String)
    case fragmented
    case empty
    case tooLong(Double)
}

/// Checks an encoded file before it is copied anywhere (plan F65): the top-level boxes tile the
/// file, `ftyp`, `moov` and `mdat` are there, nothing is fragmented, and the audio decodes to a
/// length inside the cap. An AAC file whose writer was never closed has no `moov` and fails here.
///
/// It is the phone's own first gate. The Mac's `tools/m4acheck.py` is stricter (sample
/// tables, zero padding) and host tests run it on every artefact through `scripts/check_artefacts.sh`.
public nonisolated enum M4AValidator {
    public static func validate(_ url: URL, capSeconds: Double) throws -> M4AInfo {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            throw M4AError.unreadable(error.localizedDescription)
        }
        let top = try boxes(data, from: 0, to: data.count)
        let types = Set(top.map(\.type))
        for need in ["ftyp", "moov", "mdat"] where !types.contains(need) {
            throw M4AError.missing(need)
        }
        if types.contains("moof") { throw M4AError.fragmented }
        if let moov = top.first(where: { $0.type == "moov" }),
           try boxes(data, from: moov.offset + moov.header, to: moov.offset + moov.size).contains(where: { $0.type == "mvex" }) {
            throw M4AError.fragmented
        }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw M4AError.unreadable(error.localizedDescription)
        }
        let rate = file.fileFormat.sampleRate
        guard file.length > 0, rate > 0 else { throw M4AError.empty }
        let duration = Double(file.length) / rate
        // The Mac rounds to 0.1 s before comparing with the cap (F22), so compare the same way.
        if (duration * 10).rounded() / 10 > capSeconds { throw M4AError.tooLong(duration) }
        return M4AInfo(bytes: data.count, frames: file.length, sampleRate: rate, durationSeconds: duration)
    }

    struct Box { var type: String; var offset: Int; var size: Int; var header: Int }

    /// The boxes that tile `[from, to)`, or `truncated` when they do not.
    static func boxes(_ d: Data, from: Int, to end: Int) throws -> [Box] {
        var out: [Box] = []
        var off = from
        while off < end {
            guard end - off >= 8 else { throw M4AError.truncated("\(end - off) trailing bytes at \(off)") }
            var size = Int(u32(d, off))
            let type = String(decoding: d[d.startIndex + off + 4 ..< d.startIndex + off + 8], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard end - off >= 16 else { throw M4AError.truncated("short 64-bit size at \(off)") }
                size = Int(clamping: (UInt64(u32(d, off + 8)) << 32) | UInt64(u32(d, off + 12)))
                header = 16
            } else if size == 0 {
                size = end - off
            }
            guard size >= header, off + size <= end else {
                throw M4AError.truncated("box \(type) at \(off) size \(size) overruns \(end)")
            }
            out.append(Box(type: type, offset: off, size: size, header: header))
            off += size
        }
        return out
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}
