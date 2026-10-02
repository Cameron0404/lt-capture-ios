import Foundation

/// Finds our note in the receipt (F43). An entry is ours when its `name` equals ours and its
/// `capture_id` is absent or equal to ours. `waiting-audio-off` entries carry no `capture_id`
/// (on the reference Mac side), and text notes never do, so name alone must be enough then.
/// An entry with the same name and another id is someone else's note (one written by another capture tool, say).
public nonisolated enum ReceiptMatcher {
    public static func entry(name: String, captureID: String?, in r: Receipt) -> Receipt.Entry? {
        r.captures.last { e in
            guard e.name == name else { return false }
            guard let theirs = e.capture_id, !theirs.isEmpty, let ours = captureID else { return true }
            return theirs == ours
        }
    }
}
