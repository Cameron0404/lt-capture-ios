import Foundation
import LTCaptureCore

/// `CaptureFileSystem` for the iCloud Drive folders the owner picks (plan `## Stage 5`, F9, F64, F74).
///
/// Every call runs its work inside `NSFileCoordinator` in a `@concurrent` function, so a slow
/// iCloud file never blocks the main thread. Security-scoped access is not started here: the caller
/// starts it once per send through `BookmarkStore.withAccess` and stops it in `defer`.
nonisolated struct CoordinatedFileSystem: CaptureFileSystem {
    var chunkBytes = 256 * 1024

    func list(_ dir: URL) async throws -> [String] { try await Self.list(dir) }
    func write(_ d: Data, to: URL) async throws { try await Self.write(d, to: to) }
    func copy(_ from: URL, to: URL, abort: AbortFlag) async throws { try await Self.copy(from, to: to, abort: abort, chunk: chunkBytes) }
    func move(_ from: URL, to: URL) async throws { try await Self.move(from, to: to) }
    func size(_ u: URL) async throws -> Int { try await Self.size(u) }
    func createDirectory(_ u: URL) async throws { try await Self.createDirectory(u) }
    func remove(_ u: URL) async throws { try await Self.remove(u) }

    func read(_ u: URL, timeout: Duration) async throws -> Data? {
        // A coordinated read of a file iCloud has not downloaded waits for the download, which can
        // take for ever offline, so the read races a timer (F74).
        try await withTimeout(timeout) { try await Self.read(u) }
    }

    // MARK: - The coordinated work, always off the main thread

    @concurrent static func list(_ dir: URL) async throws -> [String] {
        try coordinateRead(dir) { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw CaptureFSError.notFound(url.lastPathComponent)
            }
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }
    }

    @concurrent static func write(_ d: Data, to: URL) async throws {
        try coordinateWrite(to, options: .forReplacing) { url in try d.write(to: url) }
    }

    @concurrent static func copy(_ from: URL, to: URL, abort: AbortFlag, chunk: Int) async throws {
        try coordinateWrite(to, options: .forReplacing) { out in
            let input = try FileHandle(forReadingFrom: from)
            defer { try? input.close() }
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let output = try FileHandle(forWritingTo: out)
            defer { try? output.close() }
            while true {
                if abort.isSet { throw CaptureFSError.aborted }
                guard let bytes = try input.read(upToCount: chunk), !bytes.isEmpty else { break }
                try output.write(contentsOf: bytes)
            }
            try output.synchronize()
        }
    }

    @concurrent static func move(_ from: URL, to: URL) async throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing,
                               error: &coordError) { src, dst in
            do {
                // Never overwrite a final name (F42, F46).
                if FileManager.default.fileExists(atPath: dst.path) { throw CaptureFSError.exists(dst.lastPathComponent) }
                try FileManager.default.moveItem(at: src, to: dst)
                coordinator.item(at: src, didMoveTo: dst)
            } catch { thrown = error }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }

    @concurrent static func size(_ u: URL) async throws -> Int {
        try coordinateRead(u) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { throw CaptureFSError.notFound(url.lastPathComponent) }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    @concurrent static func createDirectory(_ u: URL) async throws {
        try coordinateWrite(u, options: []) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    @concurrent static func read(_ u: URL) async throws -> Data? {
        // A file iCloud has not downloaded shows only as `.<name>.icloud`, and the coordinated
        // read below then downloads it. With neither name present the file is missing.
        let placeholder = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) || fm.fileExists(atPath: placeholder.path) else { return nil }
        return try coordinateRead(u) { url in
            fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        }
    }

    @concurrent static func remove(_ u: URL) async throws {
        try coordinateWrite(u, options: .forDeleting) { url in try FileManager.default.removeItem(at: url) }
    }

    // MARK: - NSFileCoordinator with Swift errors

    private static func coordinateRead<T>(_ u: URL, _ body: (URL) throws -> T) throws -> T {
        var coordError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &coordError) { url in
            result = Result { try body(url) }
        }
        if let coordError { throw coordError }
        guard let result else { throw CaptureFSError.notFound(u.lastPathComponent) }
        return try result.get()
    }

    private static func coordinateWrite(_ u: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: u, options: options, error: &coordError) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }
}
