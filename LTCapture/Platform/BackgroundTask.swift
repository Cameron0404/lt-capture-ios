import UIKit
import LTCaptureCore

/// Extra time to finish the encode and the copy after the recorder stops (F17, F42, F64).
///
/// `beginBackgroundTask` is called before the recorder stops, because once the recorder stops the
/// audio background mode no longer keeps the app running. If the time runs out, the expiration
/// handler sets the abort flag, so the copy stops between chunks and leaves only its `.part`, and
/// then ends the task. The `.caf` stays in the outbox and the next launch finishes it.
@MainActor
final class BackgroundTask {
    let abort: AbortFlag
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String, abort: AbortFlag, onExpire: @escaping @MainActor () -> Void) {
        self.abort = abort
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // UIKit calls this on the main thread. The task ends before `onExpire`, because
            // `onExpire` drops the model's reference to this object, after which `self` is nil
            // and an unended expired task gets the app killed.
            MainActor.assumeIsolated {
                abort.abort()
                self?.end()
                onExpire()
            }
        }
    }

    var isActive: Bool { id != .invalid }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
