import AVFoundation
import LTCaptureCore

/// What the capture model needs from a recorder, so the app tests can drive the model with a fake
/// and never touch the microphone (plan rule 4).
@MainActor
protocol Recording: AnyObject {
    /// Asks for the microphone the first time. Called on the record press, never at launch (F76).
    func requestPermission() async -> Bool
    /// Activates the `.record` session and starts writing PCM to `url`, stopping by itself at the cap.
    func start(url: URL) throws
    func stop()
    func deactivateSession()
    /// Seconds recorded so far.
    var elapsed: TimeInterval { get }
    /// The current average level in dBFS, for the silence detector.
    func level() -> Float
    /// Called when the recorder finished by itself: `true` at the cap, `false` on an error.
    var onFinishedByItself: ((Bool) -> Void)? { get set }
}

enum RecorderError: Error, LocalizedError {
    case didNotStart
    var errorDescription: String? { "the recorder did not start" }
}

/// `AVAudioRecorder` writing 24 kHz mono 16-bit PCM to the outbox `.caf`, with metering on and
/// `record(forDuration: 599.0)` as the cap (plan `### Data`, A2). The encoder turns it into AAC after.
///
/// The delegate methods are `nonisolated` and hop to the main actor (F38), the pattern
/// `DelegateTypecheckTests` compiles on the host.
@MainActor
final class RecorderController: NSObject, Recording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var stopRequested = false
    var onFinishedByItself: ((Bool) -> Void)?

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` with no options, activated here on the press and never at launch (plan `### Stop policy`).
        try session.setCategory(.record, mode: .default, options: [])
        // iOS mutes haptics while recording unless this is set, and the start, stop and 15 s
        // silence warning haptics of the stop policy need them.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        let settings = AudioSettings.standard
        let r = try AVAudioRecorder(url: url, settings: settings.recorderSettings.mapValues { $0 as Any })
        r.isMeteringEnabled = true
        r.delegate = self
        stopRequested = false
        guard r.record(forDuration: settings.recordSeconds) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.didNotStart
        }
        recorder = r
    }

    func stop() {
        stopRequested = true
        recorder?.stop()
        recorder = nil
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func level() -> Float {
        guard let recorder else { return LevelMeter.silenceDB }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finished(flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.finished(false) }
    }

    private func finished(_ ok: Bool) {
        // A stop the app asked for is already handled. Anything else is the cap or an error.
        guard !stopRequested else { return }
        stopRequested = true
        recorder = nil
        onFinishedByItself?(ok)
    }
}
