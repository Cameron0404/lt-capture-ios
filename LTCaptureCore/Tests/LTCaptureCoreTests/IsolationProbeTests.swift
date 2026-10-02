import Testing
@testable import LTCaptureCore

@MainActor
struct IsolationProbeTests {
    @Test func concurrentFunctionRunsOffTheMainThread() async {
        #expect(onMainThread())
        let onMain = await concurrentProbe()
        #expect(onMain == false)
    }

    @Test func nonisolatedAsyncFunctionStaysOnTheCallersActor() async {
        let onMain = await nonisolatedProbe()
        #expect(onMain == true)
    }

    @Test func unannotatedFunctionIsMainActorByDefault() async {
        // A detached task starts off the main actor, so the call only lands on the main
        // thread if the default isolation really is MainActor.
        let onMain = await Task.detached { await defaultIsolationProbe() }.value
        #expect(onMain == true)
    }
}

struct VersionTests {
    @Test func nameAndVersionAreSet() {
        #expect(LTCaptureVersion.name == "LT Capture")
        #expect(LTCaptureVersion.version.split(separator: ".").count == 3)
    }
}
