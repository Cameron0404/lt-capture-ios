import Foundation

/// The body of a text note, per `## Text notes` of `docs/PROTOCOL.md` (plan F26, F80):
/// the header line in Paris time, a blank line, then the words as typed.
public nonisolated enum TextNote {
    /// nil when the text is empty after trimming, so an empty note is never sent.
    public static func body(_ text: String, at: Date) -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return nil }
        return HeaderTime.string(at) + "\n\n" + words + "\n"
    }
}
