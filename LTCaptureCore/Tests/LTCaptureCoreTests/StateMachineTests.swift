import Foundation
import Testing
@testable import LTCaptureCore

/// One case per event of the recorder's life (plan `## Stage 3`, F17, F33, F40, F41).
struct StateMachineTests {
    let stem = "2026-10-12-073015-4821"

    /// A machine that is recording `stem`.
    func recording() -> RecorderStateMachine {
        var m = RecorderStateMachine()
        #expect(m.handle(.pressed(.button)) == [.startRecorder])
        #expect(m.state == .starting)
        #expect(m.handle(.recorderStarted(stem: stem)) == [])
        #expect(m.state == .recording(stem: stem))
        return m
    }

    @Test func pressStartsTheRecorderAndNothingElse() {
        var m = RecorderStateMachine()
        #expect(m.handle(.pressed(.shortcut)) == [.startRecorder])
        #expect(m.state == .starting)
        // A second press before the recorder is up does not start a second one.
        #expect(m.handle(.pressed(.shortcut)) == [.showMessage("Starting, one moment")])
        #expect(m.state == .starting)
    }

    @Test func pressingTheShortcutAgainStops() {
        var m = recording()
        #expect(m.handle(.pressed(.shortcut)) == [.stopRecorder(.shortcut), .deactivateSession, .encode(stem: stem)])
        #expect(m.state == .encoding(stem: stem))
    }

    @Test func stopButton() {
        var m = recording()
        #expect(m.handle(.stopButton) == [.stopRecorder(.button), .deactivateSession, .encode(stem: stem)])
        var again = recording()
        #expect(again.handle(.pressed(.button)) == [.stopRecorder(.button), .deactivateSession, .encode(stem: stem)])
        // A second stop after the first is stale and ignored.
        #expect(m.handle(.stopButton) == [])
    }

    @Test func capReached() {
        var m = recording()
        #expect(m.handle(.capReached(elapsed: 599)) == [.stopRecorder(.cap), .deactivateSession,
                                                         .showMessage("Stopped at the 10 minute limit (09:59)"), .encode(stem: stem)])
        #expect(m.state == .encoding(stem: stem))
    }

    @Test func silenceWarnThenStop() {
        var m = recording()
        #expect(m.handle(.silence(.warn, elapsed: 40)) == [.haptic])
        #expect(m.state == .recording(stem: stem))
        #expect(m.handle(.silence(.stop(.silence), elapsed: 45.2)) == [.stopRecorder(.silence), .deactivateSession,
                                                                       .showMessage("Stopped after silence at 00:45"), .encode(stem: stem)])
        var q = recording()
        #expect(q.handle(.silence(.stop(.unarmedQuiet), elapsed: 12)).contains(.stopRecorder(.unarmedQuiet)))
        #expect(q.state == .encoding(stem: stem))
    }

    @Test func interruptionEndsTheNoteWithNoResume() {
        var m = recording()
        #expect(m.handle(.interruptionBegan(elapsed: 83.7)) == [.stopRecorder(.interruption), .deactivateSession,
                                                                .showMessage("ended by a call at 01:23"), .encode(stem: stem)])
        #expect(m.state == .encoding(stem: stem))
        // The interruption ending later starts nothing: only a press records.
        #expect(!m.handle(.enteredForeground).contains(.startRecorder))
    }

    @Test func mediaServicesReset() {
        var m = recording()
        #expect(m.handle(.mediaServicesReset(elapsed: 5)) == [.stopRecorder(.mediaServicesReset), .deactivateSession,
                                                              .showMessage("ended by an audio reset at 00:05"), .encode(stem: stem)])
    }

    @Test func inputLost() {
        var m = recording()
        #expect(m.handle(.inputLost(elapsed: 61)) == [.stopRecorder(.inputLost), .deactivateSession,
                                                      .showMessage("ended when the microphone went away at 01:01"), .encode(stem: stem)])
        var r = recording()
        #expect(r.handle(.routeChanged(inputAvailable: false, elapsed: 61)).first == .stopRecorder(.inputLost))
    }

    @Test func routeChangeWithInputKeptDoesNotStop() {
        var m = recording()
        #expect(m.handle(.routeChanged(inputAvailable: true, elapsed: 30)) == [])
        #expect(m.state == .recording(stem: stem))
    }

    @Test func pressWhileSendingIsIgnoredWithAMessage() {
        var m = recording()
        _ = m.handle(.stopButton)
        let busy = RecorderEffect.showMessage("Still sending the last note, try again in a moment")
        #expect(m.handle(.pressed(.button)) == [busy])
        #expect(m.handle(.encodeFinished(stem: stem)) == [.send(stem: stem)])
        #expect(m.state == .sending(stem: stem))
        #expect(m.handle(.pressed(.shortcut)) == [busy])
        #expect(m.handle(.sendFinished(stem: stem)) == [])
        #expect(m.state == .idle)
        #expect(m.handle(.pressed(.button)) == [.startRecorder])
    }

    @Test func backgroundExpiryDuringEncodeKeepsTheCaf() {
        var m = recording()
        _ = m.handle(.stopButton)
        #expect(m.handle(.backgroundTimeExpired) == [.hold(stem: stem, .backgroundExpired)])
        #expect(m.state == .idle)
        // A late encode callback for it is stale.
        #expect(m.handle(.encodeFinished(stem: stem)) == [])
        // Next launch finds the `.caf` and finishes it.
        #expect(m.handle(.launchFoundLeftover(stem: stem, heardVoice: true)) == [.encode(stem: stem)])
    }

    @Test func backgroundExpiryDuringSendAbortsTheCopy() {
        var m = recording()
        _ = m.handle(.stopButton)
        _ = m.handle(.encodeFinished(stem: stem))
        #expect(m.handle(.backgroundTimeExpired) == [.abortSend(stem: stem), .hold(stem: stem, .backgroundExpired)])
        #expect(m.state == .idle)
    }

    @Test func launchFindingACafEncodesThenSends() {
        var m = RecorderStateMachine()
        let a = "2026-10-12-070000-0001", b = "2026-10-12-071500-0002"
        #expect(m.handle(.launchFoundLeftover(stem: a, heardVoice: true)) == [.encode(stem: a)])
        #expect(m.handle(.launchFoundLeftover(stem: b, heardVoice: true)) == [])
        #expect(m.queue == [b])
        #expect(m.handle(.encodeFinished(stem: a)) == [.send(stem: a)])
        #expect(m.handle(.sendFinished(stem: a)) == [.encode(stem: b)])
        #expect(m.handle(.encodeFinished(stem: b)) == [.send(stem: b)])
        #expect(m.handle(.sendFinished(stem: b)) == [])
        #expect(m.state == .idle && m.queue.isEmpty)
    }

    @Test func aLeftoverFoundWhileRecordingWaitsForTheNewNote() {
        var m = recording()
        let old = "2026-10-11-220000-0003"
        #expect(m.handle(.launchFoundLeftover(stem: old, heardVoice: true)) == [])
        #expect(m.handle(.stopButton).last == .encode(stem: stem))
        _ = m.handle(.encodeFinished(stem: stem))
        #expect(m.handle(.sendFinished(stem: stem)) == [.encode(stem: old)])
    }

    @Test func nothingHeardHoldsAndAsksOnNextForeground() {
        var m = recording()
        #expect(m.handle(.silence(.stop(.nothingHeard), elapsed: 30)) == [.stopRecorder(.nothingHeard), .deactivateSession,
                                                                          .hold(stem: stem, .nothingHeard),
                                                                          .showMessage("Nothing heard in 00:30, kept until you say")])
        #expect(m.state == .idle)
        #expect(m.handle(.enteredForeground) == [.askDiscard(stem: stem)])
        #expect(m.handle(.discardAnswered(stem: stem, discard: true)) == [.discard(stem: stem)])
        #expect(m.handle(.enteredForeground) == [])

        // Kept instead: it is encoded and sent like any note.
        var k = recording()
        _ = k.handle(.silence(.stop(.nothingHeard), elapsed: 30))
        #expect(k.handle(.discardAnswered(stem: stem, discard: false)) == [.encode(stem: stem)])
        // A leftover with no voice is held and asked about the same way.
        var l = RecorderStateMachine()
        #expect(l.handle(.launchFoundLeftover(stem: stem, heardVoice: false)) == [.hold(stem: stem, .nothingHeard)])
        #expect(l.handle(.enteredForeground) == [.askDiscard(stem: stem)])
    }

    @Test func failuresHoldTheNoteAndFreeTheMachine() {
        var m = RecorderStateMachine()
        _ = m.handle(.pressed(.button))
        #expect(m.handle(.recorderFailedToStart("microphone not allowed")) == [.deactivateSession,
                                                                             .showMessage("Could not start recording: microphone not allowed")])
        #expect(m.state == .idle)

        var e = recording()
        _ = e.handle(.stopButton)
        #expect(e.handle(.encodeFailed(stem: stem, "fmt?")) == [.hold(stem: stem, .encodeFailed),
                                                                .showMessage("Could not encode the note: fmt?")])
        var s = recording()
        _ = s.handle(.stopButton)
        _ = s.handle(.encodeFinished(stem: stem))
        #expect(s.handle(.sendFailed(stem: stem, "folder not picked")).first == .hold(stem: stem, .sendFailed))
        #expect(s.state == .idle)
    }

    @Test func mmss() {
        #expect(RecorderStateMachine.mmss(0) == "00:00")
        #expect(RecorderStateMachine.mmss(59.99) == "00:59")
        #expect(RecorderStateMachine.mmss(599) == "09:59")
        #expect(RecorderStateMachine.mmss(-1) == "00:00")
    }
}
