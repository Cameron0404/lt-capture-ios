import AppIntents
import LTCaptureCore

/// "Record a note" for Shortcuts and the Action button (F33, F56). It opens the app in the
/// foreground, because an app may only start recording from the foreground, and starts a note. A
/// second run while a note records stops it.
struct RecordCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a note"
    static let description = IntentDescription("Starts a voice note in LT Capture, or stops the one that is recording.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureModel.shared.press(.shortcut)
        return .result()
    }
}

struct LTCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordCaptureIntent(),
                    phrases: ["Record a note with \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Record a note",
                    systemImageName: "mic.fill")
    }
}
