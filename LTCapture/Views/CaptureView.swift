import SwiftUI
import LTCaptureCore

/// The one screen the owner uses: the record button, the latest message, the status of every capture,
/// "Pick the folder again" when access fails, and the expiry banner (F8, F33, F67).
struct CaptureView: View {
    @Bindable var model: CaptureModel
    @State private var showText = false
    @State private var showSettings = false
    @State private var repick: CaptureFolder?
    /// A folder Settings asked for, opened once its sheet has finished closing.
    @State private var repickAfterSettings: CaptureFolder?

    var body: some View {
        NavigationStack {
            List {
                if model.showExpiryBanner, let expiry = model.expiry {
                    Section { ExpiryBanner(expiry: expiry) }
                }
                if let folder = model.folderProblem {
                    Section {
                        Button("Pick the folder again") { repick = folder }
                            .accessibilityHint("Choose \(folder.expectedName) in iCloud Drive")
                    } footer: {
                        Text("Your notes stay on the phone until \(folder.expectedName) can be reached.")
                    }
                }
                Section {
                    RecordButton(model: model)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .listRowBackground(Color.clear)
                    }
                }
                Section("Captures") {
                    if model.rows.isEmpty {
                        Text("Nothing sent yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.rows) { row in
                        StatusRow(row: row,
                                  onResend: { model.resend(row.id) },
                                  onDiscard: { model.answerDiscard(row.id, discard: $0) })
                    }
                }
            }
            .navigationTitle(AppInfo.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The text screen never holds the microphone, so it is closed to a running note.
                    Button("Type a note", systemImage: "square.and.pencil") { showText = true }
                        .disabled(model.state != .idle)
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showText) { TextNoteView(model: model) }
            .sheet(isPresented: $showSettings, onDismiss: {
                if let f = repickAfterSettings { repickAfterSettings = nil; repick = f }
            }) {
                SettingsView(model: model, settings: model.settings) { repickAfterSettings = $0 }
            }
            .folderPicker(for: $repick, folders: model.folders) { folder in
                Task { await model.folderPicked(folder) }
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.hapticTick)
    }
}

/// One large button: record when idle, stop while recording, with the elapsed time (F33).
struct RecordButton: View {
    let model: CaptureModel

    var body: some View {
        VStack(spacing: 12) {
            Button {
                model.isRecording ? model.stopButton() : model.press(.button)
            } label: {
                ZStack {
                    Circle()
                        .fill(model.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 180, height: 180)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.isRecording && model.state != .idle)
            .accessibilityLabel(model.isRecording ? "Stop recording" : "Record a voice note")
            .accessibilityValue(model.isRecording ? "Recording, \(RecorderStateMachine.mmss(model.elapsed))" : "")

            Text(Self.caption(model.state, elapsed: model.elapsed))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 16)
    }

    static func caption(_ state: RecorderState, elapsed: TimeInterval) -> String {
        switch state {
        case .idle: "Tap to record"
        case .starting: "Starting"
        case .recording: RecorderStateMachine.mmss(elapsed)
        case .encoding: "Encoding"
        case .sending: "Sending"
        }
    }
}

#Preview {
    CaptureView(model: .live())
}
