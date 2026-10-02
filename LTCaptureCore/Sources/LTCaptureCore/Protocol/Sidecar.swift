import Foundation

/// The JSON written beside each `.m4a`, per `### The sidecar` of `docs/PROTOCOL.md`
/// (plan F24, F55, F77, F83). Exactly these keys, `test` only when it is true. No
/// `client_transcript` and no `mac_transcribe`: the Mac transcribes the phone's audio.
public nonisolated struct Sidecar: Codable, Equatable, Sendable {
    public var audio_file: String
    public var capture_id: String
    public var spoken_at: String
    /// An integer, so the JSON never holds `48213.0` (F83).
    public var bytes: Int
    public var self_only: Bool
    public var test: Bool?
    public var duration_s: Double?

    /// The keys the protocol allows this app to write.
    public static let keys: Set<String> = ["audio_file", "capture_id", "spoken_at", "bytes", "self_only", "test", "duration_s"]

    public init(audioFile: String, captureID: String, spokenAt: String, bytes: Int,
                selfOnly: Bool = true, test: Bool = false, durationSeconds: Double? = nil) {
        audio_file = audioFile
        capture_id = captureID
        spoken_at = spokenAt
        self.bytes = bytes
        self_only = selfOnly
        self.test = test ? true : nil
        // One decimal is all the Mac could use, and it keeps 312.4 from printing as 312.39999999999998.
        duration_s = durationSeconds.map { ($0 * 10).rounded() / 10 }
    }

    /// Sorted keys, no escaped slashes. Optional fields that are nil are left out.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}
