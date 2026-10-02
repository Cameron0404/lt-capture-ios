import Foundation

/// Why a file operation stopped.
public nonisolated enum CaptureFSError: Error, Equatable, Sendable {
    /// The final name is taken, so nothing was overwritten (F42, F46).
    case exists(String)
    /// The folder or file is not there.
    case notFound(String)
    /// The abort flag was set between chunks of a copy (F42).
    case aborted
    /// A read took longer than its timeout, for example an iCloud file that never downloads (F74).
    case timedOut
    /// The file in the inbox is not the size the sidecar says (F42).
    case sizeMismatch(expected: Int, got: Int)
}

/// Set from any thread to stop a copy between chunks. The app sets it when background time runs out.
public nonisolated final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    public init() {}

    public var isSet: Bool { lock.withLock { set } }
    public func abort() { lock.withLock { set = true } }
}

/// Every file operation the outbox and delivery need, so the core is tested on temporary folders
/// with `LocalFileSystem` and the app supplies a coordinated iCloud version (plan `### Interfaces`).
///
/// The functions are plain `async`, so they run on the caller's executor. Callers that must stay
/// off the main thread (the copy, the receipt read) are `@concurrent` themselves (F64).
public nonisolated protocol CaptureFileSystem: Sendable {
    /// Names in `dir`, dot files included. Throws `notFound` when the folder is missing.
    func list(_ dir: URL) async throws -> [String]
    func write(_ d: Data, to: URL) async throws
    /// Copies in chunks, checking `abort` between them. `to` is replaced if it exists, so pass a `.part` name.
    func copy(_ from: URL, to: URL, abort: AbortFlag) async throws
    /// Renames. Throws `exists` if `to` is there, never overwriting it.
    func move(_ from: URL, to: URL) async throws
    func size(_ u: URL) async throws -> Int
    func createDirectory(_ u: URL) async throws
    /// nil when the file is missing. Throws `timedOut` after `timeout`.
    func read(_ u: URL, timeout: Duration) async throws -> Data?
    /// Only ever used on the app's own `.part` files and on outbox folders `Retention` allows.
    func remove(_ u: URL) async throws
}

/// Runs `op` and gives up after `limit`, even if `op` never returns. A task group would wait for a
/// stuck child, which is exactly the hang F74 guards against, so this races two unstructured tasks.
public nonisolated func withTimeout<T: Sendable>(_ limit: Duration,
                                                 _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once<T>()
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        once.continuation = c
        let work = Task.detached {
            do { once.resume(.success(try await op())) } catch { once.resume(.failure(error)) }
        }
        Task.detached {
            try? await Task.sleep(for: limit)
            once.resume(.failure(CaptureFSError.timedOut))
            work.cancel()
        }
    }
}

/// Resumes a continuation once, whichever side gets there first.
nonisolated final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var continuation: CheckedContinuation<T, Error>?

    func resume(_ r: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            if done { return nil }
            done = true
            return continuation
        }
        c?.resume(with: r)
    }
}
