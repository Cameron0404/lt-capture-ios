import Foundation
import Testing
import LTCaptureCore
@testable import LTCapture

// Compiles in verify.sh step 2, runs only in step 4 (a simulator runtime is needed).
// Nothing here touches the microphone, the audio session or the AAC codec: the model runs with a
// fake recorder, folders in a temporary directory, `LocalFileSystem` and a fake encoder.

/// Records what the model asked of the recorder, in order.
@MainActor
final class FakeRecorder: Recording {
    var log: [String]
    var permission = true
    var elapsedValue: TimeInterval = 0
    var levelValue: Float = -20
    var onFinishedByItself: ((Bool) -> Void)?

    init(log: [String] = []) { self.log = log }

    func requestPermission() async -> Bool { log.append("permission"); return permission }
    func start(url: URL) throws {
        log.append("start")
        // Stands in for the PCM the recorder would write.
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 4800))
    }
    func stop() { log.append("stop") }
    func deactivateSession() { log.append("deactivate") }
    var elapsed: TimeInterval { elapsedValue }
    func level() -> Float { levelValue }
}

@MainActor
final class FakeBackground: BackgroundTasking {
    let onEnd: () -> Void
    init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }
    func end() { onEnd() }
}

/// The two picked folders as plain temporary directories, so no test needs a document picker.
@MainActor
final class TempFolders: FolderAccess {
    var urls: [CaptureFolder: URL] = [:]
    var failing: Set<CaptureFolder> = []
    /// Folders whose pick throws after the name check, as an iCloud bookmark that cannot be made.
    var pickThrows: Set<CaptureFolder> = []

    func state(_ folder: CaptureFolder) -> BookmarkState {
        failing.contains(folder) ? .pickAgain : (urls[folder] == nil ? .notPicked : .ready)
    }

    func pick(_ url: URL, for folder: CaptureFolder) throws {
        guard FolderName.matches(url, expected: folder.expectedName) else {
            throw FolderAccessError.wrongFolder(expected: folder.expectedName, got: FolderName.name(of: url))
        }
        if pickThrows.contains(folder) { throw FolderAccessError.couldNotKeep(folder, reason: "not downloaded") }
        urls[folder] = url
        failing.remove(folder)
    }

    func withAccess<T>(_ folder: CaptureFolder, _ body: (URL) async throws -> T) async throws -> T {
        guard let url = urls[folder] else { throw FolderAccessError.notPicked(folder) }
        if failing.contains(folder) { throw FolderAccessError.pickAgain(folder) }
        return try await body(url)
    }
}

@MainActor
final class Harness {
    let root: URL
    let inbox: URL
    let out: URL
    let outboxRoot: URL
    let recorder: FakeRecorder
    let folders = TempFolders()
    let settings: AppSettings
    var clock: Date
    let model: CaptureModel

    init(heardVoice: Bool = true, expiry: Date? = nil, pickOut: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lt-app-\(UUID().uuidString)")
        inbox = root.appendingPathComponent("life-tracker-inbox")
        out = root.appendingPathComponent("life-tracker-out")
        outboxRoot = root.appendingPathComponent("Outbox")
        for d in [inbox, out, outboxRoot] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try folders.pick(inbox, for: .inbox)
        if pickOut { try folders.pick(out, for: .out) }
        settings = AppSettings(defaults: UserDefaults(suiteName: "lt-app-\(UUID().uuidString)")!)
        clock = Date(timeIntervalSince1970: 1_791_000_000)
        recorder = FakeRecorder()

        var box: Harness?
        let audio = AudioWork(
            encode: { _, m4a in
                try Data(repeating: 7, count: 1234).write(to: m4a)
                return EncodedAudio(bytes: 1234, seconds: 3.24)
            },
            isWhole: { _ in true },
            heardVoice: { _ in heardVoice })
        model = CaptureModel(
            settings: settings, folders: folders, recorder: recorder, outboxRoot: outboxRoot,
            outboxFS: LocalFileSystem(excludeFromBackup: true), inboxFS: LocalFileSystem(), audio: audio,
            beginBackground: { _, _ in
                box?.recorder.log.append("background")
                return FakeBackground { box?.recorder.log.append("background ended") }
            },
            expiryDate: { expiry },
            now: { box?.clock ?? Date() }, zone: { TimeZone(identifier: "Europe/London")! })
        box = self
    }

    var audioDir: URL { inbox.appendingPathComponent("audio") }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Waits for the press's own task to start the recorder, then for the queued file work.
    func waitUntilRecording() async {
        for _ in 0..<500 where !model.isRecording { await Task.yield() }
    }

    /// Makes an outbox note with only its `.caf`, as a kill mid-recording leaves it.
    func leftover(stem: String, created: Date) async throws {
        let item = try await Outbox(root: outboxRoot, fs: LocalFileSystem()).create(stem: stem, captureID: "ID-\(stem)", now: created)
        try Data(repeating: 1, count: 4800).write(to: item.cafURL)
    }
}

@MainActor
struct AppSmokeTests {
    @Test func startScreenShowsTheAppName() {
        #expect(AppInfo.title == "LT Capture")
        #expect(!AppInfo.version.isEmpty)
    }

    @Test func pressRecordsAndASecondShortcutRunStopsAndSends() async throws {
        let h = try Harness()
        h.model.press(.button)
        await h.waitUntilRecording()
        #expect(h.model.isRecording)
        h.model.press(.shortcut)
        await h.model.settle()

        #expect(h.model.state == .idle)
        // The background task starts before the recorder stops (F17, F42).
        let log = h.recorder.log
        #expect(log.prefix(2) == ["permission", "start"])
        #expect(log.firstIndex(of: "background")! < log.firstIndex(of: "stop")!)

        let names = h.names(h.audioDir)
        let m4a = try #require(names.first { $0.hasSuffix(".m4a") })
        let stem = String(m4a.dropLast(4))
        #expect(names.contains(stem + ".json"))
        #expect(!names.contains { $0.hasSuffix(".part") })
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: h.audioDir.appendingPathComponent(stem + ".json")))
        #expect(sidecar.self_only)
        #expect(sidecar.bytes == 1234)
        #expect(sidecar.test == nil)
        #expect(h.model.rows.first?.words.hasPrefix("no receipt yet") == true)
    }

    @Test func markAsTestWritesTheTestKey() async throws {
        let h = try Harness()
        h.settings.markAsTest = true
        h.model.press(.button)
        await h.waitUntilRecording()
        h.model.stopButton()
        await h.model.settle()
        let json = try #require(h.names(h.audioDir).first { $0.hasSuffix(".json") })
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: h.audioDir.appendingPathComponent(json)))
        #expect(sidecar.test == true)
    }

    @Test func deniedMicrophoneSendsNothing() async throws {
        let h = try Harness()
        h.recorder.permission = false
        h.model.press(.button)
        for _ in 0..<200 where h.model.state != .idle { await Task.yield() }
        await h.model.settle()
        #expect(h.model.state == .idle)
        #expect(!h.recorder.log.contains("start"))
        #expect(h.model.message?.contains("microphone") == true)
    }

    @Test func thirtySecondsOfNothingHoldsTheNoteAndAsks() async throws {
        let h = try Harness()
        h.model.press(.button)
        await h.waitUntilRecording()
        h.recorder.levelValue = -160
        var t: TimeInterval = 0
        while h.model.isRecording && t < 40 {
            t += 0.05
            h.recorder.elapsedValue = t
            h.model.tick()
        }
        await h.model.settle()
        #expect(!h.model.isRecording)
        #expect(h.names(h.audioDir).isEmpty)
        h.model.enteredForeground()
        await h.model.settle()
        let row = try #require(h.model.rows.first)
        #expect(row.askDiscard)
        h.model.answerDiscard(row.id, discard: true)
        await h.model.settle()
        #expect(h.names(h.outboxRoot).isEmpty)
    }

    @Test func launchSendsAVoicedLeftoverAndAsksAboutASilentOne() async throws {
        let voiced = try Harness(heardVoice: true)
        try await voiced.leftover(stem: "2026-10-01-080000-0001", created: voiced.clock)
        await voiced.model.launch()
        await voiced.model.settle()
        #expect(voiced.names(voiced.audioDir).contains("2026-10-01-080000-0001.m4a"))
        // Launch never asks for the microphone (F76).
        #expect(!voiced.recorder.log.contains("permission"))

        let silent = try Harness(heardVoice: false)
        try await silent.leftover(stem: "2026-10-01-080000-0002", created: silent.clock)
        await silent.model.launch()
        await silent.model.settle()
        #expect(!silent.names(silent.audioDir).contains("2026-10-01-080000-0002.m4a"))
        #expect(silent.model.rows.first?.askDiscard == true)
    }

    @Test func launchRemovesOnlyItsOwnPartFiles() async throws {
        let h = try Harness()
        try await h.leftover(stem: "2026-10-01-090000-0003", created: h.clock)
        try FileManager.default.createDirectory(at: h.audioDir, withIntermediateDirectories: true)
        for name in [".2026-10-01-090000-0003.m4a.part", ".someone-else.m4a.part"] {
            try Data([1]).write(to: h.audioDir.appendingPathComponent(name))
        }
        try Data([1]).write(to: h.inbox.appendingPathComponent(".dictation-2026-10-01-090000-0004.txt.part"))
        await h.model.launch()
        await h.model.settle()
        let names = h.names(h.audioDir)
        #expect(names.contains(".someone-else.m4a.part"))
        #expect(!names.contains(".2026-10-01-090000-0003.m4a.part"))
        #expect(!h.names(h.inbox).contains(".dictation-2026-10-01-090000-0004.txt.part"))
    }

    @Test func installMarkerIsWrittenOncePerExpiry() async throws {
        let expiry = Date(timeIntervalSince1970: 1_791_500_000)
        let h = try Harness(expiry: expiry)
        await h.model.launch()
        let marker = h.audioDir.appendingPathComponent(CaptureModel.installMarkerName)
        let text = try String(contentsOf: marker, encoding: .utf8)
        #expect(text.contains("profile_expires_at:"))
        #expect(h.settings.installMarkerExpiry == expiry)
        try FileManager.default.removeItem(at: marker)
        await h.model.launch()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func expiryBannerShowsInTheLastDayAndAHalf() async throws {
        let h = try Harness(expiry: Date(timeIntervalSince1970: 1_791_000_000 + 24 * 3600))
        await h.model.launch()
        #expect(h.model.showExpiryBanner)
        let early = try Harness(expiry: Date(timeIntervalSince1970: 1_791_000_000 + 5 * 24 * 3600))
        await early.model.launch()
        #expect(!early.model.showExpiryBanner)
    }

    @Test func lostFolderAccessKeepsTheNoteAndAsksForThePick() async throws {
        let h = try Harness()
        h.folders.failing = [.inbox]
        h.model.press(.button)
        await h.waitUntilRecording()
        h.model.stopButton()
        await h.model.settle()
        #expect(h.model.folderProblem == .inbox)
        #expect(h.names(h.audioDir).isEmpty)
        let outbox = try await Outbox(root: h.outboxRoot, fs: LocalFileSystem()).items()
        #expect(outbox.count == 1)
        #expect(outbox.first?.heldReason == .sendFailed)
        #expect(outbox.first?.sentAt == nil)
    }

    @Test func textNoteGoesToTheTopOfTheInboxWithoutTheMicrophone() async throws {
        let h = try Harness()
        #expect(await h.model.sendText("  buy milk  "))
        let name = try #require(h.names(h.inbox).first { $0.hasPrefix("dictation-") })
        #expect(name.hasSuffix(".txt"))
        let body = try String(contentsOf: h.inbox.appendingPathComponent(name), encoding: .utf8)
        #expect(body.hasSuffix("\n\nbuy milk\n"))
        #expect(h.recorder.log.isEmpty)
        #expect(h.model.rows.first?.kind == .text)
        #expect(await h.model.sendText("   ") == false)
    }

    @Test func retentionDeletesAFiledNoteAndKeepsAWaitingOne() async throws {
        let h = try Harness()
        let fs = LocalFileSystem()
        let outbox = Outbox(root: h.outboxRoot, fs: fs)
        let filed = try await outbox.markSent(try await outbox.create(stem: "2026-10-01-100000-0005", captureID: "A", now: h.clock), at: h.clock)
        let waiting = try await outbox.markSent(try await outbox.create(stem: "2026-10-01-100000-0006", captureID: "B", now: h.clock), at: h.clock)
        let receipt = """
        {"mac_seen_at": null, "captures": [
          {"name": "\(filed.audioName)", "capture_id": "A", "status": "filed", "filed_as": "daily note"},
          {"name": "\(waiting.audioName)", "status": "waiting-audio-off"}]}
        """
        try Data(receipt.utf8).write(to: h.out.appendingPathComponent("captures.json"))
        await h.model.launch()
        await h.model.settle()
        let left = try await outbox.items().map(\.stem)
        #expect(left == [waiting.stem])
        #expect(h.model.rows.contains { $0.words == "waiting, audio off" })
    }
}

/// The folder pick that did nothing in an early build: SwiftUI clears `isPresented` before the
/// completion, so the target must come from the `PickRequest`, and every failure must speak.
@MainActor
struct FolderPickTests {
    func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-pick-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aPickWithTheTargetHeldApartFromTheBindingIsKept() throws {
        let folders = TempFolders()
        let inbox = try tempDir("life-tracker-inbox")
        var request = PickRequest<CaptureFolder>()
        request.begin(.inbox)
        // What the old code did: the binding is already nil when the completion runs.
        let fromBinding: CaptureFolder? = nil
        #expect(FolderPickCompletion.apply(.success([inbox]), target: fromBinding, folders: folders) != nil)
        #expect(folders.state(.inbox) == .notPicked)
        // The fix: the target comes from the request.
        #expect(FolderPickCompletion.apply(.success([inbox]), target: request.take(), folders: folders) == nil)
        #expect(folders.state(.inbox) == .ready)
    }

    @Test func aTrailingSlashAndAnotherCaseAreKept() throws {
        let folders = TempFolders()
        let inbox = try tempDir("life-tracker-inbox")
        let slashed = URL(fileURLWithPath: inbox.path + "/", isDirectory: true)
        #expect(FolderPickCompletion.apply(.success([slashed]), target: .inbox, folders: folders) == nil)
        let upper = try tempDir("Life-Tracker-Out")
        #expect(FolderPickCompletion.apply(.success([upper]), target: .out, folders: folders) == nil)
        #expect(folders.state(.out) == .ready)
    }

    @Test func theWrongFolderIsRefusedWithItsName() throws {
        let folders = TempFolders()
        let out = try tempDir("life-tracker-out")
        let words = FolderPickCompletion.apply(.success([out]), target: .inbox, folders: folders)
        #expect(words == "That folder is life-tracker-out. Pick life-tracker-inbox.")
        #expect(folders.state(.inbox) == .notPicked)
    }

    @Test func everyFailureComesBackAsWords() throws {
        let folders = TempFolders()
        let inbox = try tempDir("life-tracker-inbox")
        #expect(FolderPickCompletion.apply(.success([]), target: .inbox, folders: folders)?.contains("No folder came back") == true)
        #expect(FolderPickCompletion.apply(.failure(CocoaError(.fileReadNoPermission)), target: .inbox, folders: folders) != nil)
        folders.pickThrows = [.inbox]
        let words = FolderPickCompletion.apply(.success([inbox]), target: .inbox, folders: folders)
        #expect(words?.contains("not downloaded") == true)
        #expect(folders.state(.inbox) == .notPicked)
    }

    @Test func onboardingEnablesFromTheStoredState() throws {
        let folders = TempFolders()
        func gate() -> OnboardingGate { OnboardingGate(inbox: folders.state(.inbox), out: folders.state(.out)) }
        #expect(!gate().canStart && !gate().canPickOut)
        _ = FolderPickCompletion.apply(.success([try tempDir("life-tracker-inbox")]), target: .inbox, folders: folders)
        #expect(gate().canStart && gate().canPickOut && gate().canSkipOut)
        // A failed out pick leaves the start open.
        _ = FolderPickCompletion.apply(.success([try tempDir("wrong")]), target: .out, folders: folders)
        #expect(gate().canStart && gate().canSkipOut)
        #expect(gate().startTitle == "Skip the receipt folder and start")
        _ = FolderPickCompletion.apply(.success([try tempDir("life-tracker-out")]), target: .out, folders: folders)
        #expect(gate().startTitle == "Start" && !gate().canSkipOut)
    }

    @Test func theRealBookmarkStoreKeepsAPickAcrossARelaunch() throws {
        let suite = "lt-pick-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookmarkStore(defaults: defaults)
        let inbox = try tempDir("life-tracker-inbox")
        #expect(FolderPickCompletion.apply(.success([URL(fileURLWithPath: inbox.path + "/", isDirectory: true)]),
                                           target: .inbox, folders: store) == nil)
        #expect(store.state(.inbox) == .ready)
        #expect(throws: FolderAccessError.self) { try store.pick(try tempDir("life-tracker-inbox 2"), for: .inbox) }
        // A force-quit and reopen: a new store over the same defaults still has it.
        #expect(BookmarkStore(defaults: defaults).state(.inbox) == .ready)
        #expect(BookmarkStore(defaults: defaults).state(.out) == .notPicked)
    }
}
