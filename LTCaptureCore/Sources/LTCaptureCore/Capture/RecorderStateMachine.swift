import Foundation

/// Where a press came from. Running the App Shortcut again while recording stops the note (F33).
public nonisolated enum PressSource: String, Sendable, Equatable {
    case button
    case shortcut
}

/// Why a note is held in the outbox instead of being encoded or sent.
public nonisolated enum HoldReason: String, Sendable, Equatable {
    /// Nothing voiced in the note. the owner is asked "Nothing heard, discard?" on the next foreground (F41).
    case nothingHeard
    /// Background time ran out mid-encode or mid-copy. The `.caf` stays and is finished on next launch.
    case backgroundExpired
    case encodeFailed
    case sendFailed
}

/// Everything the app tells the machine: presses, the recorder, the audio session, the silence
/// detector, the encoder, delivery and the app's own life cycle (plan `## Stage 3`, F17, F33, F40).
/// `elapsed` is seconds since the recording started, used for "ended by a call at mm:ss".
public nonisolated enum RecorderEvent: Sendable, Equatable {
    case pressed(PressSource)
    case stopButton
    case recorderStarted(stem: String)
    case recorderFailedToStart(String)
    /// `record(forDuration: 599.0)` finished by itself.
    case capReached(elapsed: TimeInterval)
    case silence(SilenceEvent, elapsed: TimeInterval)
    case interruptionBegan(elapsed: TimeInterval)
    case mediaServicesReset(elapsed: TimeInterval)
    case inputLost(elapsed: TimeInterval)
    /// A route change. It ends the note only when input actually stopped (plan `### Stop policy`).
    case routeChanged(inputAvailable: Bool, elapsed: TimeInterval)
    case encodeFinished(stem: String)
    case encodeFailed(stem: String, String)
    case sendFinished(stem: String)
    case sendFailed(stem: String, String)
    case backgroundTimeExpired
    /// Launch found `.caf` files left in the outbox with no `.m4a`. `heardVoice` is the offline
    /// `LevelMeter` plus `SilenceDetector.decide` check (F75).
    case launchFoundLeftover(stem: String, heardVoice: Bool)
    case enteredForeground
    case discardAnswered(stem: String, discard: Bool)
}

/// What the app must do in answer. The machine never touches AVFoundation or files itself.
public nonisolated enum RecorderEffect: Sendable, Equatable {
    /// Activate the `.record` session and start `AVAudioRecorder`. Only ever on a press (plan).
    case startRecorder
    case stopRecorder(StopReason)
    case deactivateSession
    case haptic
    case encode(stem: String)
    case send(stem: String)
    /// Stop the copy between chunks (the S4 abort flag).
    case abortSend(stem: String)
    case hold(stem: String, HoldReason)
    case askDiscard(stem: String)
    case discard(stem: String)
    case showMessage(String)
}

public nonisolated enum RecorderState: Sendable, Equatable {
    case idle
    case starting
    case recording(stem: String)
    case encoding(stem: String)
    case sending(stem: String)
}

/// The recorder's life as pure logic, so every stop path is tested on the host (plan `## Stage 3`).
///
/// One note is encoded or sent at a time. Notes found on launch, or stopped while another is still
/// being sent, wait in `queue`, so a finished note never waits behind a new recording.
public nonisolated struct RecorderStateMachine: Sendable {
    public private(set) var state: RecorderState = .idle
    public private(set) var queue: [String] = []
    /// Notes that heard nothing, to ask about on the next foreground.
    public private(set) var askPending: [String] = []

    public init() {}

    public mutating func handle(_ e: RecorderEvent) -> [RecorderEffect] {
        switch (state, e) {
        case (.idle, .pressed):
            state = .starting
            return [.startRecorder]
        case (.starting, .recorderStarted(let stem)):
            state = .recording(stem: stem)
            return []
        case (.starting, .recorderFailedToStart(let why)):
            return next([.deactivateSession, .showMessage("Could not start recording: \(why)")])
        case (.starting, .pressed), (.starting, .stopButton):
            return [.showMessage("Starting, one moment")]

        case (.recording(let stem), .pressed(let source)):
            return stop(stem, source == .shortcut ? .shortcut : .button, message: nil)
        case (.recording(let stem), .stopButton):
            return stop(stem, .button, message: nil)
        case (.recording(let stem), .capReached(let t)):
            return stop(stem, .cap, message: "Stopped at the 10 minute limit (\(Self.mmss(t)))")
        case (.recording, .silence(.warn, _)):
            return [.haptic]
        case (.recording(let stem), .silence(.stop(.nothingHeard), let t)):
            askPending.append(stem)
            return next([.stopRecorder(.nothingHeard), .deactivateSession, .hold(stem: stem, .nothingHeard),
                         .showMessage("Nothing heard in \(Self.mmss(t)), kept until you say")])
        case (.recording(let stem), .silence(.stop(let r), let t)):
            return stop(stem, r, message: "Stopped after silence at \(Self.mmss(t))")
        case (.recording(let stem), .interruptionBegan(let t)):
            // The system has already stopped the recorder. No automatic resume (plan).
            return stop(stem, .interruption, message: "ended by a call at \(Self.mmss(t))")
        case (.recording(let stem), .mediaServicesReset(let t)):
            return stop(stem, .mediaServicesReset, message: "ended by an audio reset at \(Self.mmss(t))")
        case (.recording(let stem), .inputLost(let t)),
             (.recording(let stem), .routeChanged(false, let t)):
            return stop(stem, .inputLost, message: "ended when the microphone went away at \(Self.mmss(t))")
        case (.recording, .routeChanged(true, _)):
            return []

        case (.encoding, .pressed), (.sending, .pressed):
            return [.showMessage("Still sending the last note, try again in a moment")]

        case (.encoding(let s), .encodeFinished(let stem)) where s == stem:
            state = .sending(stem: stem)
            return [.send(stem: stem)]
        case (.encoding(let s), .encodeFailed(let stem, let why)) where s == stem:
            return next([.hold(stem: stem, .encodeFailed), .showMessage("Could not encode the note: \(why)")])
        case (.encoding(let stem), .backgroundTimeExpired):
            // The `.caf` stays in the outbox, and launch finds it again.
            return next([.hold(stem: stem, .backgroundExpired)])
        case (.sending(let s), .sendFinished(let stem)) where s == stem:
            return next([])
        case (.sending(let s), .sendFailed(let stem, let why)) where s == stem:
            return next([.hold(stem: stem, .sendFailed), .showMessage("Not sent yet, kept in the outbox: \(why)")])
        case (.sending(let stem), .backgroundTimeExpired):
            return next([.abortSend(stem: stem), .hold(stem: stem, .backgroundExpired)])

        case (_, .launchFoundLeftover(let stem, let heardVoice)):
            guard !heardVoice else { return enqueue(stem) }
            askPending.append(stem)
            return [.hold(stem: stem, .nothingHeard)]
        case (.recording, .enteredForeground):
            return []
        case (_, .enteredForeground):
            return askPending.map { .askDiscard(stem: $0) }
        case (_, .discardAnswered(let stem, let discard)):
            guard let i = askPending.firstIndex(of: stem) else { return [] }
            askPending.remove(at: i)
            return discard ? [.discard(stem: stem)] : enqueue(stem)

        default:
            // Anything else is stale (a late recorder callback, a second stop): ignore it.
            return []
        }
    }

    private mutating func stop(_ stem: String, _ r: StopReason, message: String?) -> [RecorderEffect] {
        var out: [RecorderEffect] = [.stopRecorder(r), .deactivateSession]
        if let message { out.append(.showMessage(message)) }
        state = .idle
        // The note just stopped goes first. Leftovers queued during the recording follow it.
        return out + enqueue(stem)
    }

    /// Starts the encode now when nothing else is being encoded or sent, else queues it.
    private mutating func enqueue(_ stem: String) -> [RecorderEffect] {
        switch state {
        case .idle:
            state = .encoding(stem: stem)
            return [.encode(stem: stem)]
        default:
            queue.append(stem)
            return []
        }
    }

    /// Ends the current encode or send and moves to the next queued note.
    private mutating func next(_ effects: [RecorderEffect]) -> [RecorderEffect] {
        state = .idle
        guard !queue.isEmpty else { return effects }
        return effects + enqueue(queue.removeFirst())
    }

    /// `mm:ss` for the messages, from seconds since the recording started.
    public static func mmss(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
