import Foundation
import Testing
@testable import LTCaptureCore

// The pattern the app's `RecorderController` uses with the system recorder's delegate protocol (plan F38): a
// `@MainActor` model whose delegate methods are `nonisolated` and hop back with
// `Task { @MainActor in }`. This file must compile under the package's Swift 6 flags
// (`.defaultIsolation(MainActor.self)`, `NonisolatedNonsendingByDefault`). The system calls
// the real delegate on a queue of its own, so the fake below does too.

/// Shaped like the system recorder's delegate protocol: a class protocol, `Sendable`, not isolated to any actor.
nonisolated protocol RecorderDelegateShape: AnyObject, Sendable {
    func audioRecorderDidFinishRecording(_ recorder: FakeRecorder, successfully flag: Bool)
    func audioRecorderEncodeErrorDidOccur(_ recorder: FakeRecorder, error: (any Error)?)
}

/// Stands in for the system recorder, which calls its delegate off the main thread.
nonisolated final class FakeRecorder: Sendable {
    let elapsed: TimeInterval
    init(elapsed: TimeInterval) { self.elapsed = elapsed }

    func finish(to delegate: any RecorderDelegateShape) async {
        await Task.detached { delegate.audioRecorderDidFinishRecording(self, successfully: true) }.value
    }
}

@MainActor
final class RecorderModel: RecorderDelegateShape {
    var machine = RecorderStateMachine()
    var effects: [RecorderEffect] = []
    var delegateRanOnMain: Bool?
    var errors = 0

    nonisolated func audioRecorderDidFinishRecording(_ recorder: FakeRecorder, successfully flag: Bool) {
        let offMain = !onMainThread()
        let elapsed = recorder.elapsed
        Task { @MainActor in
            self.delegateRanOnMain = !offMain
            self.effects += self.machine.handle(.capReached(elapsed: elapsed))
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: FakeRecorder, error: (any Error)?) {
        Task { @MainActor in self.errors += 1 }
    }
}

@MainActor
struct DelegateTypecheckTests {
    @Test func nonisolatedDelegateHopsToTheMainActor() async throws {
        let model = RecorderModel()
        _ = model.machine.handle(.pressed(.button))
        _ = model.machine.handle(.recorderStarted(stem: "s"))
        await FakeRecorder(elapsed: 599).finish(to: model)
        for _ in 0..<200 where model.effects.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.delegateRanOnMain == false)
        #expect(model.effects.first == .stopRecorder(.cap))
        #expect(model.machine.state == .encoding(stem: "s"))
    }
}
