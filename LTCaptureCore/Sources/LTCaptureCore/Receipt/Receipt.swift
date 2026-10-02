import Foundation

/// `life-tracker-out/captures.json`, as `## The receipt` of `docs/PROTOCOL.md` defines it.
/// Decoded leniently: unknown keys are ignored, an entry without a name is skipped, and an unknown
/// status reads as "received" (plan `### Data`, **Receipt**).
public nonisolated struct Receipt: Decodable, Sendable, Equatable {
    public let mac_seen_at: String?
    public let captures: [Entry]

    public init(mac_seen_at: String?, captures: [Entry]) {
        self.mac_seen_at = mac_seen_at
        self.captures = captures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        mac_seen_at = try? c.decodeIfPresent(String.self, forKey: .mac_seen_at)
        let raw = (try? c.decodeIfPresent([Lenient].self, forKey: .captures)) ?? []
        captures = raw.compactMap(\.entry)
    }

    enum Keys: String, CodingKey { case mac_seen_at, captures }

    public nonisolated struct Entry: Decodable, Sendable, Equatable {
        public let name: String
        public let capture_id: String?
        public let status: String
        public let filed_as: String?
        public let first_seen_at: String?
        public let at: String?

        public init(name: String, capture_id: String? = nil, status: String, filed_as: String? = nil,
                    first_seen_at: String? = nil, at: String? = nil) {
            self.name = name
            self.capture_id = capture_id
            self.status = status
            self.filed_as = filed_as
            self.first_seen_at = first_seen_at
            self.at = at
        }

        public var kind: EntryStatus { EntryStatus(rawValue: status) ?? .other }
    }

    /// One array element that may not decode, so one bad entry never hides the rest.
    struct Lenient: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    public static func decode(_ data: Data) throws -> Receipt {
        try JSONDecoder().decode(Receipt.self, from: data)
    }
}

/// The four statuses `## The receipt` lists, and anything else.
public nonisolated enum EntryStatus: String, Sendable, Equatable {
    case filed
    case failed
    case waitingAudioOff = "waiting-audio-off"
    case needsCam = "needs-cam"
    case other
}

/// What reading the receipt gave.
public nonisolated enum ReceiptState: Sendable, Equatable {
    /// the owner has not picked `life-tracker-out` (it is optional, F4).
    case notPicked
    /// No `captures.json` yet: the Mac has never written one (F58).
    case missing
    /// Timed out, or not JSON. Shown as unknown and read again later (F74).
    case unreadable
    case read(Receipt)
}

/// Reads `captures.json` off the main thread with a timeout, because an iCloud file that is not
/// downloaded can block a coordinated read (F64, F74).
public nonisolated enum ReceiptReader {
    public static let fileName = "captures.json"

    @concurrent
    public static func load(fs: any CaptureFileSystem, outFolder: URL?, timeout: Duration = .seconds(10)) async -> ReceiptState {
        guard let outFolder else { return .notPicked }
        do {
            guard let data = try await fs.read(outFolder.appendingPathComponent(fileName), timeout: timeout) else { return .missing }
            return .read(try Receipt.decode(data))
        } catch {
            return .unreadable
        }
    }
}
