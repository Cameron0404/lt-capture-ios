import SwiftUI

/// The text field (F70): type or dictate with any keyboard, then send it into the top of the
/// inbox as `dictation-<stem>.txt`. It is the only way the app files anything before `audio on`.
///
/// This screen never starts the recorder or the audio session, so the microphone is free for the
/// keyboard's own dictation while the field is focused.
struct TextNoteView: View {
    let model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Type or dictate a note", text: $text, axis: .vertical)
                        .lineLimit(5...20)
                        .focused($focused)
                } footer: {
                    Text("Sent as a text note to life-tracker-inbox. The Mac files it like a dictation.")
                }
                if let message = model.message, !sending {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Text note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sending = true
                        Task {
                            let sent = await model.sendText(text)
                            sending = false
                            if sent { dismiss() }
                        }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
