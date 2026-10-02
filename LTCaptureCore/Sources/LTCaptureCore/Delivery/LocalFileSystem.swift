import Foundation

/// `CaptureFileSystem` on plain local files: the outbox in `Library/Application Support`, and the
/// host tests' temporary folders. No file coordination, which iCloud folders need (the app's S5 job).
public nonisolated struct LocalFileSystem: CaptureFileSystem {
    /// Set on the outbox, so voice audio never goes into an iCloud or Finder backup (F32).
    public var excludeFromBackup: Bool
    public var chunkBytes: Int
    /// Called after each chunk a copy writes, with the bytes so far. Tests use it to abort mid-copy.
    public var onChunk: (@Sendable (Int) -> Void)?

    public init(excludeFromBackup: Bool = false, chunkBytes: Int = 256 * 1024,
                onChunk: (@Sendable (Int) -> Void)? = nil) {
        self.excludeFromBackup = excludeFromBackup
        self.chunkBytes = chunkBytes
        self.onChunk = onChunk
    }

    public func list(_ dir: URL) async throws -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CaptureFSError.notFound(dir.lastPathComponent)
        }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    public func write(_ d: Data, to: URL) async throws {
        try d.write(to: to, options: .atomic)
        try exclude(to)
    }

    public func copy(_ from: URL, to: URL, abort: AbortFlag) async throws {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: to.path, contents: nil)
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        var total = 0
        while true {
            if abort.isSet { throw CaptureFSError.aborted }
            guard let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            total += chunk.count
            onChunk?(total)
        }
        try output.synchronize()
        try exclude(to)
    }

    public func move(_ from: URL, to: URL) async throws {
        // moveItem refuses an existing name too. The check first gives the error a name.
        if FileManager.default.fileExists(atPath: to.path) { throw CaptureFSError.exists(to.lastPathComponent) }
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func size(_ u: URL) async throws -> Int {
        guard FileManager.default.fileExists(atPath: u.path) else { throw CaptureFSError.notFound(u.lastPathComponent) }
        let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    public func createDirectory(_ u: URL) async throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try exclude(u)
    }

    public func read(_ u: URL, timeout: Duration) async throws -> Data? {
        try await withTimeout(timeout) {
            guard FileManager.default.fileExists(atPath: u.path) else { return nil }
            return try Data(contentsOf: u)
        }
    }

    public func remove(_ u: URL) async throws {
        try FileManager.default.removeItem(at: u)
    }

    private func exclude(_ u: URL) throws {
        guard excludeFromBackup else { return }
        var url = u
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
