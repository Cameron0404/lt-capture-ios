import Testing
@testable import LTCaptureCore

/// Folder access (plan F4, F9): every failure ends on "Pick the folder again", never on a lost capture.
struct BookmarkTests {
    func picked() -> BookmarkStateMachine {
        var m = BookmarkStateMachine()
        #expect(m.state == .notPicked && m.state.words == "Pick the folder")
        #expect(m.handle(.picked) == .ready)
        return m
    }

    @Test func resolveFails() {
        var m = picked()
        #expect(m.handle(.resolveFailed) == .pickAgain)
        #expect(m.state.words == "Pick the folder again")
        #expect(!m.state.canUse)
        #expect(m.handle(.picked) == .ready)
    }

    @Test func startReturnsFalse() {
        var m = picked()
        #expect(m.handle(.resolved(stale: false)) == .ready)
        #expect(m.handle(.startFailed) == .pickAgain)
    }

    @Test func anEmptyListingGetsOneRetry() {
        var m = picked()
        #expect(m.handle(.listed(empty: true)) == .ready)
        #expect(m.retryListing)
        #expect(m.handle(.listed(empty: true)) == .pickAgain)
        #expect(!m.retryListing)

        // A retry that lists something clears the flag.
        var n = picked()
        n.handle(.listed(empty: true))
        #expect(n.handle(.listed(empty: false)) == .ready)
        #expect(!n.retryListing)
        #expect(n.handle(.listed(empty: true)) == .ready)
    }

    @Test func staleThenResaved() {
        var m = picked()
        #expect(m.handle(.resolved(stale: true)) == .needsResave)
        #expect(m.state.canUse)
        // Resolving again before the re-save does not lose the stale mark.
        #expect(m.handle(.resolved(stale: false)) == .needsResave)
        #expect(m.handle(.resaved) == .ready)

        var n = picked()
        n.handle(.resolved(stale: true))
        #expect(n.handle(.resaveFailed) == .pickAgain)
    }

    @Test func nothingHappensBeforeAPick() {
        var m = BookmarkStateMachine()
        for e in [BookmarkEvent.resolved(stale: false), .resolveFailed, .startFailed, .listed(empty: true), .resaved, .pickCancelled] {
            #expect(m.handle(e) == .notPicked)
        }
    }
}
