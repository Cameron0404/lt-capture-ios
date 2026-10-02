import Foundation

/// What a capture's row says (plan `### Status words shown to the owner`, F21, F44, F57, F74, F81).
public nonisolated enum CaptureStatus: Sendable, Equatable {
    case filed(String)
    case filedCamToLook(String)
    case taskFailed
    case waitingAudioOff
    case received
    case sent
    case notTakenYet
    case takenNotFiled
    case notConfirmed
    case receiptFolderNotPicked
    case noReceiptYet
    case unknown
    /// Still on the phone, not yet copied.
    case notSentYet
    case held(HoldReason)

    public var words: String {
        switch self {
        case .filed(let a): "filed: \(a)"
        case .filedCamToLook(let a): "filed, worth a look: \(a)"
        case .taskFailed: "task failed (the Mac has the note)"
        case .waitingAudioOff: "waiting, audio off"
        case .received: "received"
        case .sent: "sent"
        case .notTakenYet: "not taken yet, is the Mac awake?"
        case .takenNotFiled: "taken, not yet filed"
        case .notConfirmed: "not confirmed, check the vault"
        case .receiptFolderNotPicked: "receipt folder not picked"
        case .noReceiptYet: "no receipt yet"
        case .unknown: "unknown, will check again"
        case .notSentYet: "on the phone, not sent yet"
        case .held(.nothingHeard): "nothing heard, discard?"
        case .held(.backgroundExpired): "stopped in the background, finishing on next open"
        case .held(.encodeFailed): "could not encode, kept on the phone"
        case .held(.sendFailed): "could not send, kept on the phone"
        }
    }

    /// "sent" carries the upload words from the app (`UploadState`), the others stand alone.
    public func words(upload: String?) -> String {
        guard self == .sent, let upload, !upload.isEmpty else { return words }
        return words + ", " + upload
    }
}

/// Turns the receipt and the file's place into one status. The receipt comes first, then the
/// place, and a note is never called filed from where it sits (F44).
public nonisolated enum StatusResolver {
    /// "not taken yet" after this long in `audio/` (settings `notConfirmedAfterAudioOffMinutes`).
    public static let notTakenAfter: TimeInterval = 3 * 60
    /// "not confirmed" after this long in `audio/processed/` (`notConfirmedAfterAudioOnMinutes`).
    public static let notConfirmedAfter: TimeInterval = 45 * 60

    public static func status(_ item: OutboxItem, entry: Receipt.Entry?, placement: Placement,
                              receiptState: ReceiptState, now: Date) -> CaptureStatus {
        guard let sentAt = item.sentAt else { return item.heldReason.map(CaptureStatus.held) ?? .notSentYet }
        if let entry { return status(entry) }
        switch receiptState {
        case .notPicked: return .receiptFolderNotPicked
        case .missing: return .noReceiptYet
        case .unreadable: return .unknown
        case .read: break
        }
        let age = now.timeIntervalSince(sentAt)
        switch placement {
        case .inAudio: return age < notTakenAfter ? .sent : .notTakenYet
        case .inProcessed: return age < notConfirmedAfter ? .takenNotFiled : .notConfirmed
        case .absent, .unknown: return .unknown
        }
    }

    /// A text note has no place to watch once the Mac takes it, so with no entry it is "sent"
    /// until 45 minutes and "not confirmed" after, never "failed" (F23).
    public static func textStatus(sentAt: Date, entry: Receipt.Entry?, receiptState: ReceiptState, now: Date) -> CaptureStatus {
        if let entry { return status(entry) }
        if case .notPicked = receiptState { return .receiptFolderNotPicked }
        return now.timeIntervalSince(sentAt) < notConfirmedAfter ? .sent : .notConfirmed
    }

    public static func status(_ e: Receipt.Entry) -> CaptureStatus {
        switch e.kind {
        case .filed: .filed(e.filed_as ?? "")
        case .needsCam: .filedCamToLook(e.filed_as ?? "")
        case .failed: .taskFailed
        case .waitingAudioOff: .waitingAudioOff
        case .other: .received
        }
    }

    /// A resend is offered only when no entry exists and the guard says the file is in neither
    /// folder. Any entry, even `failed` written over `filed`, means the Mac has the note (F81).
    public static func offersResend(entry: Receipt.Entry?, decision: ResendDecision) -> Bool {
        entry == nil && decision == .send
    }
}
