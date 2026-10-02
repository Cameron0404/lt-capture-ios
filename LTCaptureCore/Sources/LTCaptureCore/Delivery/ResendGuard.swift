import Foundation

public nonisolated enum ResendDecision: Sendable, Equatable {
    case send
    /// The Mac already has it in `audio/` or `audio/processed/`.
    case alreadyThere
    /// A listing failed or came back empty, so nobody can say. Never a send (F74).
    case unknown
}

/// Where a sent note is now, from the two listings. The Mac moves a taken note into `audio/processed/`.
public nonisolated enum Placement: Sendable, Equatable {
    case inAudio
    case inProcessed
    /// Both listings are known and neither holds the name.
    case absent
    case unknown
}

/// Decides whether a voice note may be copied into `audio/` (F46, F74).
///
/// The Mac never dedupes on `capture_id` and writes a second copy as `-2` (the reference Mac side's
/// behaviour), so a blind resend makes a duplicate note. A copy happens only when
/// neither `audio/<name>` nor `audio/processed/<name>` exists and both listings are known.
///
/// An iCloud placeholder `.<name>.icloud`, a file not yet downloaded to this phone, counts as there.
/// `audio/` is never legitimately empty once the Mac has run (it holds `processed/`), so an empty
/// `audio/` listing is treated like a failed one. An empty `processed/` is normal while audio is off.
public nonisolated enum ResendGuard {
    public static func decision(name: String, audioListing: [String]?, processedListing: [String]?) -> ResendDecision {
        switch placement(name: name, audioListing: audioListing, processedListing: processedListing) {
        case .inAudio, .inProcessed: .alreadyThere
        case .absent: .send
        case .unknown: .unknown
        }
    }

    public static func placement(name: String, audioListing: [String]?, processedListing: [String]?) -> Placement {
        if let a = audioListing, holds(a, name) { return .inAudio }
        if let p = processedListing, holds(p, name) { return .inProcessed }
        guard let a = audioListing, !a.isEmpty, processedListing != nil else { return .unknown }
        return .absent
    }

    static func holds(_ listing: [String], _ name: String) -> Bool {
        listing.contains(name) || listing.contains("." + name + ".icloud")
    }
}
