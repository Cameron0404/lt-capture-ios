import Foundation

/// The app's name and version, shown on the start screen.
public enum LTCaptureVersion {
    public nonisolated static let name = "LT Capture"
    public nonisolated static let version = "0.1.0"
}

// Isolation probes (plan F64, P4). They exist so a host test can prove the package
// really runs with `.defaultIsolation(MainActor.self)` and `NonisolatedNonsendingByDefault`,
// which later stages rely on to keep the encode and the file copy off the main thread.

/// Synchronous on purpose: Swift 6 refuses `Thread.isMainThread` inside an `async` function.
public nonisolated func onMainThread() -> Bool { Thread.isMainThread }

/// `@concurrent` always runs on the global concurrent executor, so off the main thread.
@concurrent public func concurrentProbe() async -> Bool { onMainThread() }

/// With `NonisolatedNonsendingByDefault` a plain nonisolated async function runs on the caller's actor.
public nonisolated func nonisolatedProbe() async -> Bool { onMainThread() }

/// No annotation, so `.defaultIsolation(MainActor.self)` makes it main-actor isolated.
public func defaultIsolationProbe() -> Bool { onMainThread() }
