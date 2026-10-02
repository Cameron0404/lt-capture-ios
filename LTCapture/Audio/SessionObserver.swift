import AVFoundation
import LTCaptureCore

/// What the audio session tells the recorder, turned into plain values.
enum SessionChange: Equatable, Sendable {
    case interruptionBegan
    case mediaServicesReset
    /// A route change. `inputAvailable` is false when the microphone actually went away.
    case routeChanged(inputAvailable: Bool)
}

/// Watches the audio session while a note records (plan `### Stop policy`, F40).
///
/// Interruptions end the note, which is then sent, with no automatic resume. iOS 27 replaces the
/// interruption notification with `didBecomeInactiveNotification` and
/// `resumptionRecommendationNotification`, so both are observed there and the old one before. A
/// route change ends the note only when input actually stopped, which the model decides from
/// `inputAvailable`.
@MainActor
final class SessionObserver {
    private var tokens: [NSObjectProtocol] = []
    private let onChange: (SessionChange) -> Void

    init(onChange: @escaping (SessionChange) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        if #available(iOS 27, *) {
            observe(center, AVAudioSession.didBecomeInactiveNotification, session) { _ in .interruptionBegan }
            // A recommendation to resume is ignored on purpose: the note already ended and was sent.
            observe(center, AVAudioSession.resumptionRecommendationNotification, session) { _ in nil }
        } else {
            observe(center, AVAudioSession.interruptionNotification, session) { info in
                let raw = (info[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                return raw == AVAudioSession.InterruptionType.began.rawValue ? .interruptionBegan : nil
            }
        }
        observe(center, AVAudioSession.mediaServicesWereResetNotification, session) { _ in .mediaServicesReset }
        observe(center, AVAudioSession.routeChangeNotification, session) { _ in
            let s = AVAudioSession.sharedInstance()
            return .routeChanged(inputAvailable: s.isInputAvailable && !s.currentRoute.inputs.isEmpty)
        }
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    /// `map` runs on the posting thread and returns a `Sendable` value, which is then handed to the
    /// main actor, so no `Notification` crosses threads.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ object: AnyObject,
                         _ map: @escaping @Sendable ([AnyHashable: Any]) -> SessionChange?) {
        let token = center.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
            guard let change = map(note.userInfo ?? [:]) else { return }
            Task { @MainActor in self?.onChange(change) }
        }
        tokens.append(token)
    }
}
