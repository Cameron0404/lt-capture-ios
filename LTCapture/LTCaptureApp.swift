import SwiftUI
import LTCaptureCore

@main
struct LTCaptureApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CaptureModel.shared
    @State private var launched = false

    var body: some Scene {
        WindowGroup {
            Group {
                if model.settings.onboarded {
                    CaptureView(model: model)
                } else {
                    OnboardingView(folders: model.folders) {
                        model.settings.onboarded = true
                        Task { await model.launch() }
                    }
                }
            }
            // Launch work is files only: salvage, clean-up, retention, the install marker. The
            // microphone and the audio session wait for the first press (F76).
            .task {
                guard !launched else { return }
                launched = true
                await model.launch()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.enteredForeground()
            case .background: model.isForeground = false
            default: break
            }
        }
    }
}

extension CaptureModel {
    /// One model for the app and the App Shortcut, so a second run of the shortcut stops the note
    /// the first one started (F33).
    static let shared = CaptureModel.live()
}

/// The app's name and version, for the title and Settings.
enum AppInfo {
    static let title = LTCaptureVersion.name

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? LTCaptureVersion.version
    }
}
