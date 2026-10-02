import Foundation
import LTCaptureCore

/// The two folders the owner picks once: `life-tracker-inbox` (required) and `life-tracker-out` (optional).
nonisolated enum CaptureFolder: String, CaseIterable, Sendable {
    case inbox
    case out

    /// The name the folder must have, from `## Folders` of `docs/PROTOCOL.md`.
    var expectedName: String {
        switch self {
        case .inbox: "life-tracker-inbox"
        case .out: "life-tracker-out"
        }
    }
}

nonisolated enum FolderAccessError: Error, Equatable, LocalizedError {
    case notPicked(CaptureFolder)
    case pickAgain(CaptureFolder)
    case wrongFolder(expected: String, got: String)
    /// The folder had the right name but could not be kept, with the system's reason.
    case couldNotKeep(CaptureFolder, reason: String)
    /// The picker finished without saying which folder it was opened for.
    case noTarget
    /// The picker finished with no folder in its result.
    case nothingPicked

    var errorDescription: String? {
        switch self {
        case .notPicked(let f): "\(f.expectedName) is not picked yet"
        case .pickAgain(let f): "Pick \(f.expectedName) again"
        case .wrongFolder(let expected, let got):
            got.isEmpty ? "That is not a named folder. Pick \(expected)." : "That folder is \(got). Pick \(expected)."
        case .couldNotKeep(let f, let reason):
            "\(f.expectedName) could not be kept: \(reason). If iCloud Drive is still downloading it, wait a moment and pick it again."
        case .noTarget: "The folder picker did not say which folder it was for. Tap the pick button again."
        case .nothingPicked: "No folder came back from the picker. Open the folder so its name is the title, then tap Open."
        }
    }
}

/// How the model reaches the picked folders. The app uses `BookmarkStore`, and the app tests use
/// plain temporary folders, so no test needs a document picker.
@MainActor
protocol FolderAccess: AnyObject {
    func state(_ folder: CaptureFolder) -> BookmarkState
    /// Keeps a folder the owner just picked. Throws `wrongFolder` when its name is not the protocol's.
    func pick(_ url: URL, for folder: CaptureFolder) throws
    /// Resolves the folder, starts access once, runs `body`, and stops access in `defer` (F4, F9).
    func withAccess<T>(_ folder: CaptureFolder, _ body: (URL) async throws -> T) async throws -> T
}

/// Security-scoped bookmarks for the two folders, kept in `UserDefaults` (plan `### Data`).
///
/// Bookmarks resolve with `withoutImplicitStartAccessing`, so access starts exactly once per use,
/// here, and stops in `defer`. A stale bookmark is used and then saved again. Every failure moves
/// the folder to "Pick the folder again" through `BookmarkStateMachine`, and the capture stays in
/// the outbox (F9).
@MainActor
final class BookmarkStore: FolderAccess {
    private let defaults: UserDefaults
    private var machines: [CaptureFolder: BookmarkStateMachine] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for f in CaptureFolder.allCases {
            machines[f] = BookmarkStateMachine(state: defaults.data(forKey: Self.key(f)) == nil ? .notPicked : .ready)
        }
    }

    static func key(_ f: CaptureFolder) -> String { "bookmark.\(f.rawValue)" }

    func state(_ folder: CaptureFolder) -> BookmarkState { machines[folder]?.state ?? .notPicked }

    func pick(_ url: URL, for folder: CaptureFolder) throws {
        // The picker can return a directory URL with a trailing "/", and iCloud Drive does not
        // promise case, so the name is compared on the standardised path (FolderName).
        guard FolderName.matches(url, expected: folder.expectedName) else {
            throw FolderAccessError.wrongFolder(expected: folder.expectedName, got: FolderName.name(of: url))
        }
        // A URL from the document picker needs access started before it can be bookmarked.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw FolderAccessError.couldNotKeep(folder, reason: (error as NSError).localizedDescription)
        }
        defaults.set(data, forKey: Self.key(folder))
        guard defaults.data(forKey: Self.key(folder)) == data else {
            throw FolderAccessError.couldNotKeep(folder, reason: "the bookmark was not saved")
        }
        handle(.picked, folder)
    }

    func withAccess<T>(_ folder: CaptureFolder, _ body: (URL) async throws -> T) async throws -> T {
        guard let data = defaults.data(forKey: Self.key(folder)) else { throw FolderAccessError.notPicked(folder) }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withoutImplicitStartAccessing],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            handle(.resolveFailed, folder)
            throw FolderAccessError.pickAgain(folder)
        }
        handle(.resolved(stale: stale), folder)
        guard url.startAccessingSecurityScopedResource() else {
            handle(.startFailed, folder)
            throw FolderAccessError.pickAgain(folder)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        if stale {
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.key(folder))
                handle(.resaved, folder)
            } else {
                handle(.resaveFailed, folder)
            }
        }
        // A bookmark that resolves after a reboot can list nothing once (plan `## Risks`), so an
        // empty listing is tried once more before the folder is called lost.
        for _ in 0..<2 {
            let names = (try? await CoordinatedFileSystem.list(url)) ?? []
            handle(.listed(empty: names.isEmpty), folder)
            if !names.isEmpty || state(folder) == .pickAgain { break }
        }
        guard state(folder).canUse else { throw FolderAccessError.pickAgain(folder) }
        return try await body(url)
    }

    private func handle(_ e: BookmarkEvent, _ f: CaptureFolder) {
        var m = machines[f] ?? BookmarkStateMachine()
        m.handle(e)
        machines[f] = m
    }
}
