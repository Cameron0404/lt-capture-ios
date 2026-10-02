import Foundation

/// When the phone may delete its own copy of a voice note .
///
/// The default is 14 days after sending. It ends early only when the Mac has finished with the
/// audio for good: `filed`, or `needs-cam` after the Mac's own checks, which write "kept, over 10 min"
/// on the reference Mac side, or "kept, unclear audio". Every other entry keeps the full 14 days:
/// `waiting-audio-off` ("not transcribed, audio intake is off") has not been transcribed yet,
/// "kept, name mismatch" and "kept, not self only" were stopped before any check, and `failed`
/// may be retried.
/// A note never sent is never deleted.
public nonisolated enum Retention {
    public static let keepDays = 14
    public static let doneWords: Set<String> = ["kept, over 10 min", "kept, unclear audio"]

    public static func canDelete(_ item: OutboxItem, entry: Receipt.Entry?, now: Date) -> Bool {
        guard let sentAt = item.sentAt else { return false }
        if let entry {
            switch entry.kind {
            case .filed: return true
            case .needsCam where doneWords.contains(entry.filed_as ?? ""): return true
            default: break
            }
        }
        return now.timeIntervalSince(sentAt) >= TimeInterval(keepDays * 24 * 3600)
    }
}
