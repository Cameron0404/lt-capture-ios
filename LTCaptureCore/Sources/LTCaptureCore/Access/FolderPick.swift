import Foundation

/// The name check for a folder picked in the document picker (plan F4). The picker can hand back
/// a directory URL with a trailing "/", and iCloud Drive does not promise the case the owner typed, so
/// the check compares the last path component of the standardised path, ignoring case and any
/// trailing "/".
public nonisolated enum FolderName {
    /// The last component of `path`, without trailing "/". Empty for "" or "/".
    public static func lastComponent(of path: String) -> String {
        var p = Substring(path)
        while p.hasSuffix("/") { p = p.dropLast() }
        if let slash = p.lastIndex(of: "/") { p = p[p.index(after: slash)...] }
        return String(p)
    }

    /// The name the owner sees for `url`, from its standardised path.
    public static func name(of url: URL) -> String {
        lastComponent(of: url.standardizedFileURL.path(percentEncoded: false))
    }

    public static func matches(_ name: String, expected: String) -> Bool {
        lastComponent(of: name).caseInsensitiveCompare(lastComponent(of: expected)) == .orderedSame
    }

    public static func matches(_ url: URL, expected: String) -> Bool {
        matches(name(of: url), expected: expected)
    }
}

/// The folder a document picker was opened for, held apart from the `isPresented` binding.
///
/// SwiftUI sets `isPresented` to false *before* it calls `onCompletion` (Apple's documentation of
/// `fileImporter`). A target derived from that binding is therefore already gone when the
/// completion runs, and the pick is dropped without a word. The target lives here instead and is
/// taken exactly once by the completion.
public nonisolated struct PickRequest<Target: Sendable & Equatable>: Sendable, Equatable {
    public private(set) var target: Target?

    public init() {}

    public mutating func begin(_ target: Target) { self.target = target }

    /// Returns the target the picker was opened for and clears it.
    public mutating func take() -> Target? {
        defer { target = nil }
        return target
    }
}

/// What the setup screen enables, from the stored state of the two folders (plan F4).
/// `life-tracker-inbox` is required, `life-tracker-out` only adds the receipt, so nothing about the
/// out folder, including a failed pick of it, ever blocks the start once the inbox is ready.
public nonisolated struct OnboardingGate: Sendable, Equatable {
    public var inbox: BookmarkState
    public var out: BookmarkState

    public init(inbox: BookmarkState, out: BookmarkState) {
        self.inbox = inbox
        self.out = out
    }

    public var inboxDone: Bool { inbox.canUse }
    public var outDone: Bool { out.canUse }
    public var canPickOut: Bool { inboxDone }
    public var canStart: Bool { inboxDone }
    /// "Skip for now" shows while the inbox is ready and the out folder is not.
    public var canSkipOut: Bool { inboxDone && !outDone }
    public var startTitle: String { outDone ? "Start" : "Skip the receipt folder and start" }
}
