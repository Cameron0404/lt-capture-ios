import SwiftUI
import LTCaptureCore

/// Two switches and the two folders (plan `### Data`, **Settings**). The silence numbers are
/// constants, stated in the README, not settings.
struct SettingsView: View {
    let model: CaptureModel
    @Bindable var settings: AppSettings
    /// Asks the capture screen to open its folder picker once this sheet has gone, so only one
    /// file importer is ever live after setup.
    let onRepick: (CaptureFolder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Stop after silence", isOn: $settings.silenceStopEnabled)
                } footer: {
                    Text("Stops 20 seconds after you stop talking, or after 30 seconds if nothing is heard. The limit is 10 minutes either way.")
                }
                Section {
                    Toggle("Mark captures as tests", isOn: $settings.markAsTest)
                } footer: {
                    Text("Adds \"test\": true to each note's sidecar, so the Mac can tell trial notes apart.")
                }
                Section("Folders") {
                    ForEach(CaptureFolder.allCases, id: \.self) { folder in
                        Button {
                            onRepick(folder)
                            dismiss()
                        } label: {
                            LabeledContent(folder.expectedName,
                                           value: model.folders.state(folder).words ?? "Picked")
                        }
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: AppInfo.version)
                    if let expiry = model.expiry {
                        LabeledContent("Signing lapses", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
