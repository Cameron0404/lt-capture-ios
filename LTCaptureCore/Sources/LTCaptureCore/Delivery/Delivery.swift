import Foundation

public nonisolated enum SendResult: Sendable, Equatable {
    /// Both files are in `audio/` under their final names and the audio is the size the sidecar says.
    case sent
    /// The Mac already has it (a copy that finished before a kill, F46). The caller marks it sent.
    case alreadyThere
    /// A listing failed or was empty, so nothing was copied. Try again later (F74).
    case unknown
}

/// Copies a note into the life tracker inbox the way `docs/PROTOCOL.md` asks (`## What a good app producer does`
/// step 4, plan F42, F46, F58): both files as dot-named `.part` files first, which the Mac ignores,
/// then the audio renamed, then the sidecar, then the audio's size checked against the sidecar.
///
/// Both sends are `@concurrent`, so the copy never runs on the main thread (F64).
public nonisolated struct Delivery: Sendable {
    public let fs: any CaptureFileSystem
    public let abort: AbortFlag
    public var listTimeout: Duration

    public init(fs: any CaptureFileSystem, abort: AbortFlag = AbortFlag(), listTimeout: Duration = .seconds(10)) {
        self.fs = fs
        self.abort = abort
        self.listTimeout = listTimeout
    }

    public static func partName(_ name: String) -> String { "." + name + ".part" }

    @concurrent
    public func sendAudio(_ item: OutboxItem, inbox: URL) async throws -> SendResult {
        let audioDir = inbox.appendingPathComponent("audio", isDirectory: true)
        let processed = audioDir.appendingPathComponent("processed", isDirectory: true)
        let audioPart = audioDir.appendingPathComponent(Self.partName(item.audioName))
        let sidecarPart = audioDir.appendingPathComponent(Self.partName(item.sidecarName))

        let decision: ResendDecision
        switch await listing(audioDir) {
        case .missing:
            // First send ever: the app makes `audio/` and knows it is empty (F58).
            try await fs.createDirectory(audioDir)
            decision = .send
        case .failed:
            decision = .unknown
        case .names(let names):
            // Our own leftovers from a copy that was aborted or killed go first (F42).
            for part in [audioPart, sidecarPart] where names.contains(part.lastPathComponent) {
                try await fs.remove(part)
            }
            let processedNames: [String]?
            switch await listing(processed) {
            case .missing: processedNames = []
            case .failed: processedNames = nil
            case .names(let p): processedNames = p
            }
            let visible = names.filter { $0 != audioPart.lastPathComponent && $0 != sidecarPart.lastPathComponent }
            decision = ResendGuard.decision(name: item.audioName, audioListing: visible, processedListing: processedNames)
        }
        switch decision {
        case .unknown: return .unknown
        case .alreadyThere: return .alreadyThere
        case .send: break
        }

        guard let sidecarData = try await fs.read(item.sidecarURL, timeout: listTimeout) else {
            throw CaptureFSError.notFound(item.sidecarName)
        }
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: sidecarData)

        try await fs.copy(item.m4aURL, to: audioPart, abort: abort)
        if abort.isSet { throw CaptureFSError.aborted }
        try await fs.write(sidecarData, to: sidecarPart)
        try await fs.move(audioPart, to: audioDir.appendingPathComponent(item.audioName))
        try await fs.move(sidecarPart, to: audioDir.appendingPathComponent(item.sidecarName))
        let got = try await fs.size(audioDir.appendingPathComponent(item.audioName))
        guard got == sidecar.bytes else { throw CaptureFSError.sizeMismatch(expected: sidecar.bytes, got: got) }
        return .sent
    }

    /// A text note into the top of the inbox as `dictation-<stem>.txt`, through `.<name>.part`
    /// (F23, F80). Returns the name, or nil when the text is empty after trimming, sending nothing.
    @concurrent
    public func sendTextNote(_ text: String, at: Date, zone: TimeZone, suffix: Int, inbox: URL) async throws -> String? {
        guard let body = TextNote.body(text, at: at) else { return nil }
        let name = CaptureNaming.textName(start: at, zone: zone, suffix: suffix)
        try await sendText(name, body: body, inbox: inbox)
        return name
    }

    public func sendText(_ name: String, body: String, inbox: URL) async throws {
        let part = inbox.appendingPathComponent(Self.partName(name))
        try await fs.write(Data(body.utf8), to: part)
        try await fs.move(part, to: inbox.appendingPathComponent(name))
    }

    enum Listing { case missing, failed, names([String]) }

    func listing(_ dir: URL) async -> Listing {
        let fs = self.fs
        do {
            return .names(try await withTimeout(listTimeout) { try await fs.list(dir) })
        } catch CaptureFSError.notFound {
            return .missing
        } catch {
            return .failed
        }
    }
}
