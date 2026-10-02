import Foundation
@testable import LTCaptureCore

/// A fresh temporary folder for one test. Never the real drop folders (plan rule 5).
func tempFolder(_ label: String) -> URL {
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltcap-s4-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// `LocalFileSystem` that writes down every change it makes, and the thread each call ran on,
/// so a test can check the order of events and that the copy ran off the main thread (F42, F64).
final class RecordingFileSystem: CaptureFileSystem, @unchecked Sendable {
    let inner: LocalFileSystem
    private let lock = NSLock()
    private var _events: [String] = []
    private var _mainThreadCalls: [String] = []
    /// When set, `list` of a folder with this name fails, like an iCloud folder that will not list.
    var failListing: String?

    init(_ inner: LocalFileSystem = LocalFileSystem()) { self.inner = inner }

    var events: [String] { lock.withLock { _events } }
    var mainThreadCalls: [String] { lock.withLock { _mainThreadCalls } }

    private func note(_ e: String, log: Bool = true) {
        let main = onMainThread()
        lock.withLock {
            if log { _events.append(e) }
            if main { _mainThreadCalls.append(e) }
        }
    }

    func list(_ dir: URL) async throws -> [String] {
        note("list \(dir.lastPathComponent)", log: false)
        if dir.lastPathComponent == failListing { throw CocoaError(.fileReadUnknown) }
        return try await inner.list(dir)
    }
    func write(_ d: Data, to: URL) async throws {
        note("write \(to.lastPathComponent)")
        try await inner.write(d, to: to)
    }
    func copy(_ from: URL, to: URL, abort: AbortFlag) async throws {
        note("copy \(to.lastPathComponent)")
        try await inner.copy(from, to: to, abort: abort)
    }
    func move(_ from: URL, to: URL) async throws {
        note("move \(from.lastPathComponent) -> \(to.lastPathComponent)")
        try await inner.move(from, to: to)
    }
    func size(_ u: URL) async throws -> Int {
        note("size \(u.lastPathComponent)")
        return try await inner.size(u)
    }
    func createDirectory(_ u: URL) async throws {
        note("mkdir \(u.lastPathComponent)")
        try await inner.createDirectory(u)
    }
    func read(_ u: URL, timeout: Duration) async throws -> Data? {
        note("read \(u.lastPathComponent)", log: false)
        return try await inner.read(u, timeout: timeout)
    }
    func remove(_ u: URL) async throws {
        note("remove \(u.lastPathComponent)")
        try await inner.remove(u)
    }
}

/// A file system whose reads never finish in time, like a coordinated read of an iCloud file
/// that is not downloaded (F74).
struct StuckFileSystem: CaptureFileSystem {
    func list(_ dir: URL) async throws -> [String] { [] }
    func write(_ d: Data, to: URL) async throws {}
    func copy(_ from: URL, to: URL, abort: AbortFlag) async throws {}
    func move(_ from: URL, to: URL) async throws {}
    func size(_ u: URL) async throws -> Int { 0 }
    func createDirectory(_ u: URL) async throws {}
    func read(_ u: URL, timeout: Duration) async throws -> Data? {
        try await withTimeout(timeout) {
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
    }
    func remove(_ u: URL) async throws {}
}

/// An outbox capture with a fake `.m4a` of `bytes` bytes and a sidecar that says so.
func makeOutboxItem(_ outbox: Outbox, stem: String = "2026-10-12-073015-4821", bytes: Int = 300_000,
                    sidecarBytes: Int? = nil) async throws -> OutboxItem {
    let item = try await outbox.create(stem: stem, captureID: "5B0E3C1A-0000-4000-8000-000000000001",
                                       now: Date(timeIntervalSince1970: 1_791_000_000))
    var data = Data(count: bytes)
    for i in stride(from: 0, to: bytes, by: 997) { data[i] = UInt8(i % 251) }
    try await outbox.fs.write(data, to: item.m4aURL)
    let sidecar = Sidecar(audioFile: item.audioName, captureID: item.captureID,
                          spokenAt: "2026-10-12T07:30:15+02:00", bytes: sidecarBytes ?? bytes, durationSeconds: 60)
    try await outbox.fs.write(try sidecar.encoded(), to: item.sidecarURL)
    return item
}

/// Whether the backup exclusion is on the file. It reads the extended attribute that setting
/// `isExcludedFromBackup` writes, because on the Mac host reading the resource value back
/// returns false even straight after a successful set (seen on Darwin 27, 30 Sep 2026).
func isMarkedExcludedFromBackup(_ u: URL) -> Bool {
    getxattr(u.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) > 0
}
