import Foundation

/// `state.json` in each capture's outbox folder (plan `### Data`, **Outbox**).
public nonisolated struct OutboxState: Codable, Equatable, Sendable {
    public var capture_id: String
    public var created_at: Date
    public var sent_at: Date?
    public var last_status: String?
    public var held_reason: String?

    public init(captureID: String, createdAt: Date) {
        capture_id = captureID
        created_at = createdAt
    }
}

/// One voice note in the outbox: `<root>/<stem>/` holding `<stem>.caf`, `<stem>.m4a`,
/// `<stem>.json` and `state.json`.
public nonisolated struct OutboxItem: Equatable, Sendable {
    public var stem: String
    public var folder: URL
    public var state: OutboxState

    public init(stem: String, folder: URL, state: OutboxState) {
        self.stem = stem
        self.folder = folder
        self.state = state
    }

    public var audioName: String { CaptureNaming.audioName(stem: stem) }
    public var sidecarName: String { CaptureNaming.sidecarName(stem: stem) }
    public var cafURL: URL { folder.appendingPathComponent(stem + ".caf") }
    public var m4aURL: URL { folder.appendingPathComponent(audioName) }
    public var sidecarURL: URL { folder.appendingPathComponent(sidecarName) }
    public var stateURL: URL { folder.appendingPathComponent("state.json") }
    public var captureID: String { state.capture_id }
    public var sentAt: Date? { state.sent_at }
    public var heldReason: HoldReason? { state.held_reason.flatMap(HoldReason.init(rawValue:)) }
}

/// The phone's own copy of every voice note until `Retention` lets it go. It lives in
/// `Library/Application Support/Outbox/`, so a new install over the old one keeps it (F8).
public nonisolated struct Outbox: Sendable {
    public let root: URL
    public let fs: any CaptureFileSystem

    public init(root: URL, fs: any CaptureFileSystem) {
        self.root = root
        self.fs = fs
    }

    /// Makes the folder and writes `state.json` before any audio exists, so a kill at any later
    /// point leaves a folder the next launch can finish.
    public func create(stem: String, captureID: String, now: Date) async throws -> OutboxItem {
        let folder = root.appendingPathComponent(stem, isDirectory: true)
        try await fs.createDirectory(folder)
        let item = OutboxItem(stem: stem, folder: folder, state: OutboxState(captureID: captureID, createdAt: now))
        try await save(item)
        return item
    }

    public func save(_ item: OutboxItem) async throws {
        try await fs.write(try Self.encoder.encode(item.state), to: item.stateURL)
    }

    /// Records the send. Called only after `Delivery.sendAudio` says `sent` or `alreadyThere`.
    public func markSent(_ item: OutboxItem, at: Date) async throws -> OutboxItem {
        var done = item
        done.state.sent_at = at
        done.state.held_reason = nil
        try await save(done)
        return done
    }

    public func hold(_ item: OutboxItem, _ reason: HoldReason) async throws -> OutboxItem {
        var held = item
        held.state.held_reason = reason.rawValue
        try await save(held)
        return held
    }

    /// Every capture folder with a readable `state.json`, oldest first.
    public func items() async throws -> [OutboxItem] {
        let names: [String]
        do { names = try await fs.list(root) } catch CaptureFSError.notFound { return [] }
        var out: [OutboxItem] = []
        for name in names where !name.hasPrefix(".") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let stateURL = folder.appendingPathComponent("state.json")
            guard let data = try? await fs.read(stateURL, timeout: .seconds(10)),
                  let state = try? Self.decoder.decode(OutboxState.self, from: data) else { continue }
            out.append(OutboxItem(stem: name, folder: folder, state: state))
        }
        return out.sorted { $0.state.created_at < $1.state.created_at }
    }

    /// Captures whose `.caf` was never encoded, for the salvage on launch (F17).
    public func leftovers() async throws -> [OutboxItem] {
        var out: [OutboxItem] = []
        for item in try await items() where item.sentAt == nil {
            let names = (try? await fs.list(item.folder)) ?? []
            if names.contains(item.stem + ".caf") && !names.contains(item.audioName) { out.append(item) }
        }
        return out
    }

    /// Deletes a capture's folder. The caller must have asked `Retention.canDelete` first.
    public func remove(_ item: OutboxItem) async throws {
        try await fs.remove(item.folder)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
