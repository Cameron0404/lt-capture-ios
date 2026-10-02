import Foundation

/// Where one picked folder stands (`life-tracker-inbox` required, `life-tracker-out` optional).
public nonisolated enum BookmarkState: Sendable, Equatable {
    case notPicked
    case ready
    /// The bookmark resolved but is stale: use it, then save a fresh one.
    case needsResave
    /// Something failed. The capture stays in the outbox and the owner sees "Pick the folder again".
    case pickAgain

    public var canUse: Bool { self == .ready || self == .needsResave }

    public var words: String? {
        switch self {
        case .notPicked: "Pick the folder"
        case .pickAgain: "Pick the folder again"
        case .ready, .needsResave: nil
        }
    }
}

/// What the app saw while using the bookmark: resolve with `withoutImplicitStartAccessing`, one
/// `startAccessingSecurityScopedResource` per send with the stop in `defer`, then a listing.
public nonisolated enum BookmarkEvent: Sendable, Equatable {
    case picked
    case pickCancelled
    case resolved(stale: Bool)
    case resolveFailed
    /// `startAccessingSecurityScopedResource()` returned false.
    case startFailed
    case listed(empty: Bool)
    case resaved
    case resaveFailed
}

/// Folder access as pure logic (plan F4, F9). Any failure lands on `pickAgain` and never touches
/// the capture. An empty listing gets one retry first, because a bookmark that resolves after a
/// reboot can list nothing once before it lists the folder (Apple bug r.150542999, plan `## Risks`).
public nonisolated struct BookmarkStateMachine: Sendable {
    public private(set) var state: BookmarkState
    /// Set after one empty listing, so the app lists once more before giving up.
    public private(set) var retryListing = false

    public init(state: BookmarkState = .notPicked) { self.state = state }

    @discardableResult
    public mutating func handle(_ e: BookmarkEvent) -> BookmarkState {
        switch e {
        case .picked:
            state = .ready
            retryListing = false
        case .pickCancelled:
            break
        case .resolved(let stale):
            guard state != .notPicked else { break }
            state = stale ? .needsResave : (state == .needsResave ? .needsResave : .ready)
        case .resolveFailed, .startFailed, .resaveFailed:
            guard state != .notPicked else { break }
            state = .pickAgain
            retryListing = false
        case .listed(let empty):
            guard state.canUse else { break }
            if !empty { retryListing = false }
            else if retryListing { state = .pickAgain; retryListing = false }
            else { retryListing = true }
        case .resaved:
            if state == .needsResave { state = .ready }
        }
        return state
    }
}
