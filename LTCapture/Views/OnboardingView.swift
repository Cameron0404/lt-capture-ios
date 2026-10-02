import SwiftUI
import UniformTypeIdentifiers
import LTCaptureCore

/// The two folder picks, once (F4): `life-tracker-inbox` is required, `life-tracker-out` is
/// optional and only adds the receipt. Each is a single-folder pick in iCloud Drive.
struct OnboardingView: View {
    let folders: any FolderAccess
    let onDone: () -> Void
    @State private var repick: CaptureFolder?
    /// Read from the stored bookmarks on appear and after every pick, so the buttons follow what
    /// was actually kept rather than what the picker said.
    @State private var gate = OnboardingGate(inbox: .notPicked, out: .notPicked)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("LT Capture copies each note into your life tracker inbox in iCloud Drive.")
                step(.inbox, text: "Pick life-tracker-inbox. The app needs it to send anything.",
                     done: gate.inboxDone, enabled: true)
                step(.out, text: "Then pick life-tracker-out, where the Mac writes what it filed. You can skip this and pick it later in Settings.",
                     done: gate.outDone, enabled: gate.canPickOut)
                if gate.canSkipOut {
                    Button("Skip for now") { onDone() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button {
                    onDone()
                } label: {
                    Text(gate.startTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!gate.canStart)
            }
            .padding()
            .navigationTitle("Set up")
            .folderPicker(for: $repick, folders: folders) { _ in refreshGate() }
            .onAppear { refreshGate() }
        }
    }

    private func refreshGate() {
        gate = OnboardingGate(inbox: folders.state(.inbox), out: folders.state(.out))
    }

    private func step(_ folder: CaptureFolder, text: String, done: Bool, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
            Button(done ? "\(folder.expectedName) picked" : "Pick \(folder.expectedName)",
                   systemImage: done ? "checkmark.circle.fill" : "folder") { repick = folder }
                .buttonStyle(.bordered)
                .disabled(!enabled)
        }
    }
}

extension View {
    /// A single-folder document picker for `folder`, kept through `FolderAccess.pick`. A folder
    /// with the wrong name is refused with the name it should have.
    func folderPicker(for folder: Binding<CaptureFolder?>, folders: any FolderAccess,
                      picked: @escaping (CaptureFolder) -> Void) -> some View {
        modifier(FolderPickerModifier(folder: folder, folders: folders, picked: picked))
    }
}

/// What a finished pick did, kept apart from the view so the app tests can drive it.
@MainActor
enum FolderPickCompletion {
    /// Keeps the picked folder for `target`. Returns nil when it was kept, or the words for the
    /// alert. Every failure, including a missing target, comes back as text, never as silence.
    static func apply(_ result: Result<[URL], any Error>, target: CaptureFolder?,
                      folders: any FolderAccess) -> String? {
        guard let target else { return FolderAccessError.noTarget.localizedDescription }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return FolderAccessError.nothingPicked.localizedDescription }
            do {
                try folders.pick(url, for: target)
                return folders.state(target).canUse ? nil
                    : "\(target.expectedName) was picked but cannot be used yet. Pick it again."
            } catch {
                return error.localizedDescription
            }
        case .failure(let e):
            return e.localizedDescription
        }
    }
}

/// One file importer per presentation context. The folder it was opened for is held in a
/// `PickRequest`, because SwiftUI sets `isPresented` to false before it calls `onCompletion`, so a
/// target read from the binding is already nil by then (the bug where the pick did nothing).
private struct FolderPickerModifier: ViewModifier {
    @Binding var folder: CaptureFolder?
    let folders: any FolderAccess
    let picked: (CaptureFolder) -> Void
    @State private var presented = false
    @State private var request = PickRequest<CaptureFolder>()
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $presented, allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                let target = request.take()
                error = FolderPickCompletion.apply(result, target: target, folders: folders)
                // The caller rereads the stored state after every pick, kept or not.
                if let target { picked(target) }
            } onCancellation: {
                _ = request.take()
            }
            .onChange(of: folder) { _, new in
                guard let new else { return }
                request.begin(new)
                presented = true
            }
            .onChange(of: presented) { _, now in
                if !now { folder = nil }
            }
            .alert("That folder was not kept", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
}
