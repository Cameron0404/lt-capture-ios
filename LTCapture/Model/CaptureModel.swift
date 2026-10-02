import Foundation
import Observation
import LTCaptureCore

/// Extra time from the system while a note is encoded and sent. `BackgroundTask` in the app, a
/// fake in the tests.
@MainActor
protocol BackgroundTasking: AnyObject {
    func end()
}

extension BackgroundTask: BackgroundTasking {}

/// What an encode gave, enough for the sidecar.
nonisolated struct EncodedAudio: Sendable, Equatable {
    var bytes: Int
    var seconds: Double
}

/// The audio work that needs the codec: the encode, the check that an `.m4a` is whole, and the
/// "any voice?" check on a `.caf` found at launch (F75). The tests pass fakes, so no app test needs
/// the AAC codec or the microphone.
nonisolated struct AudioWork: Sendable {
    var encode: @Sendable (_ caf: URL, _ m4a: URL) async throws -> EncodedAudio
    var isWhole: @Sendable (_ m4a: URL) async -> Bool
    var heardVoice: @Sendable (_ caf: URL) async -> Bool

    static let live = AudioWork(
        encode: { caf, m4a in
            let r = try await Encoder.encode(caf: caf, to: m4a, settings: .standard)
            return EncodedAudio(bytes: r.bytes, seconds: r.durationSeconds)
        },
        isWhole: { m4a in await Self.validates(m4a) },
        heardVoice: { caf in await Self.heard(caf) })

    @concurrent static func validates(_ m4a: URL) async -> Bool {
        (try? M4AValidator.validate(m4a, capSeconds: AudioSettings.standard.protocolCapSeconds)) != nil
    }

    /// The offline level check. A file that cannot be read counts as voiced, so it is sent and the
    /// Mac decides, rather than being held on a guess.
    @concurrent static func heard(_ caf: URL) async -> Bool {
        guard let ticks = try? LevelMeter.ticks(pcm: caf, every: SilenceConfig.standard.tick) else { return true }
        return SilenceDetector.decide(ticks).heardVoice
    }
}

/// A text note the app sent, kept so its row can show the receipt (F23, F70).
nonisolated struct SentText: Codable, Equatable, Sendable {
    var name: String
    var sentAt: Date
}

/// One line of the status list.
struct StatusItem: Identifiable, Equatable {
    enum Kind: Equatable { case voice, text }
    var id: String
    var kind: Kind
    var when: Date
    var words: String
    /// Only when no receipt entry exists and the guard says the file is in neither folder (F81).
    var canResend: Bool
    var askDiscard: Bool
}

/// Everything the capture screen shows and does. It feeds `RecorderStateMachine` and carries out
/// the effects it returns, so the order of every stop path is the one S3 tested on the host.
///
/// File work (create, encode, send, hold, discard) runs one piece at a time on `work`, so two
/// writes to one `state.json` never race. Stopping the recorder and aborting a copy happen at once.
@MainActor
@Observable
final class CaptureModel {
    // MARK: What the screen reads

    private(set) var state: RecorderState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var message: String?
    private(set) var rows: [StatusItem] = []
    /// Which folder the owner must pick again, shown as "Pick the folder again" (F9).
    private(set) var folderProblem: CaptureFolder?
    private(set) var expiry: Date?
    private(set) var showExpiryBanner = false
    /// Changes on every start, stop and silence warning, for `.sensoryFeedback`.
    private(set) var hapticTick = 0
    var isForeground = true

    var isRecording: Bool { if case .recording = state { true } else { false } }

    // MARK: Parts

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let folders: any FolderAccess
    @ObservationIgnored private var recorder: any Recording
    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored private let inboxFS: any CaptureFileSystem
    @ObservationIgnored private let audio: AudioWork
    @ObservationIgnored private let beginBackground: (AbortFlag, @escaping @MainActor () -> Void) -> any BackgroundTasking
    @ObservationIgnored private let uploadWords: (URL) -> String?
    @ObservationIgnored private let expiryDate: () -> Date?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let zone: () -> TimeZone
    @ObservationIgnored private var observer: SessionObserver?

    @ObservationIgnored private var machine = RecorderStateMachine()
    @ObservationIgnored private var detector = SilenceDetector()
    @ObservationIgnored private var items: [String: OutboxItem] = [:]
    @ObservationIgnored private var recordingItem: OutboxItem?
    @ObservationIgnored private var askDiscard: [String] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var background: (any BackgroundTasking)?
    @ObservationIgnored private var abort = AbortFlag()

    init(settings: AppSettings, folders: any FolderAccess, recorder: any Recording, outboxRoot: URL,
         outboxFS: any CaptureFileSystem, inboxFS: any CaptureFileSystem, audio: AudioWork,
         beginBackground: @escaping (AbortFlag, @escaping @MainActor () -> Void) -> any BackgroundTasking,
         uploadWords: @escaping (URL) -> String? = { _ in nil },
         expiryDate: @escaping () -> Date? = { nil },
         now: @escaping () -> Date = Date.init, zone: @escaping () -> TimeZone = { .current },
         observeSession: Bool = false) {
        self.settings = settings
        self.folders = folders
        self.recorder = recorder
        self.outbox = Outbox(root: outboxRoot, fs: outboxFS)
        self.inboxFS = inboxFS
        self.audio = audio
        self.beginBackground = beginBackground
        self.uploadWords = uploadWords
        self.expiryDate = expiryDate
        self.now = now
        self.zone = zone
        self.recorder.onFinishedByItself = { [weak self] atCap in self?.recorderFinishedByItself(atCap) }
        if observeSession {
            observer = SessionObserver { [weak self] change in self?.sessionChanged(change) }
        }
    }

    /// The app's model: the real recorder, bookmarks, iCloud coordination and the outbox in
    /// `Library/Application Support/Outbox/`, excluded from backup (plan `### Data`).
    static func live() -> CaptureModel {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CaptureModel(
            settings: AppSettings(), folders: BookmarkStore(), recorder: RecorderController(),
            outboxRoot: support.appendingPathComponent("Outbox", isDirectory: true),
            outboxFS: LocalFileSystem(excludeFromBackup: true), inboxFS: CoordinatedFileSystem(),
            audio: .live,
            beginBackground: { abort, onExpire in BackgroundTask(name: "Send the note", abort: abort, onExpire: onExpire) },
            uploadWords: { UploadStatusReader.words(for: $0) },
            expiryDate: { ProvisioningExpiry.expiry() },
            observeSession: true)
    }

    // MARK: Presses

    /// The big button and the App Shortcut. A second press while recording stops (F33, F56).
    func press(_ source: PressSource = .button) {
        send(.pressed(source))
    }

    func stopButton() {
        send(.stopButton)
    }

    func answerDiscard(_ stem: String, discard: Bool) {
        send(.discardAnswered(stem: stem, discard: discard))
    }

    /// "Send again", offered only when `StatusResolver.offersResend` says so. The encode is skipped
    /// when the `.m4a` is whole, and `Delivery` checks both folders again before any copy.
    func resend(_ stem: String) {
        send(.launchFoundLeftover(stem: stem, heardVoice: true))
    }

    func enteredForeground() {
        isForeground = true
        send(.enteredForeground)
        enqueueWork { await self.refresh() }
    }

    func clearMessage() { message = nil }

    // MARK: The state machine

    private func send(_ e: RecorderEvent) {
        let effects = machine.handle(e)
        state = machine.state
        for effect in effects { perform(effect) }
        state = machine.state
        endBackgroundIfIdle()
    }

    private func perform(_ effect: RecorderEffect) {
        switch effect {
        case .startRecorder:
            Task { await self.startRecording() }
        case .stopRecorder:
            stopRecording()
        case .deactivateSession:
            recorder.deactivateSession()
        case .haptic:
            hapticTick += 1
        case .showMessage(let text):
            message = text
        case .abortSend:
            abort.abort()
        case .askDiscard(let stem):
            if !askDiscard.contains(stem) { askDiscard.append(stem) }
            enqueueWork { await self.refresh() }
        case .encode(let stem):
            enqueueWork { await self.encode(stem) }
        case .send(let stem):
            enqueueWork { await self.deliver(stem) }
        case .hold(let stem, let reason):
            enqueueWork { await self.hold(stem, reason) }
        case .discard(let stem):
            askDiscard.removeAll { $0 == stem }
            enqueueWork { await self.discard(stem) }
        }
    }

    // MARK: Recording

    private func startRecording() async {
        // The microphone is asked for here, on the press, never at launch (F76).
        guard await recorder.requestPermission() else {
            send(.recorderFailedToStart("the microphone is not allowed. Turn it on in Settings, LT Capture"))
            return
        }
        let start = now()
        let stem = CaptureNaming.stem(start: start, zone: zone(), suffix: CaptureNaming.randomSuffix())
        do {
            let item = try await outbox.create(stem: stem, captureID: UUID().uuidString, now: start)
            items[stem] = item
            try recorder.start(url: item.cafURL)
            recordingItem = item
        } catch {
            send(.recorderFailedToStart(error.localizedDescription))
            return
        }
        detector = SilenceDetector(SilenceConfig(enabled: settings.silenceStopEnabled))
        elapsed = 0
        message = nil
        observer?.start()
        hapticTick += 1
        send(.recorderStarted(stem: stem))
        startTicker()
    }

    private func startTicker() {
        ticker?.cancel()
        let every = Duration.milliseconds(Int(SilenceConfig.standard.tick * 1000))
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// One 50 ms tick: the level into `SilenceDetector`, its event into the machine (plan `### Stop policy`).
    func tick() {
        guard isRecording else { return }
        elapsed = recorder.elapsed
        if let event = detector.feed(dB: recorder.level(), at: elapsed, foreground: isForeground) {
            send(.silence(event, elapsed: elapsed))
        }
    }

    private func stopRecording() {
        // The background task starts before the recorder stops, because the audio mode stops
        // keeping the app alive the moment recording ends (F17, F42).
        beginBackgroundIfNeeded()
        elapsed = max(elapsed, recorder.elapsed)
        ticker?.cancel()
        ticker = nil
        observer?.stop()
        recorder.stop()
        hapticTick += 1
        if let item = recordingItem { Self.excludeFromBackup(item.cafURL) }
        recordingItem = nil
    }

    private func recorderFinishedByItself(_ atCap: Bool) {
        let t = max(elapsed, recorder.elapsed)
        send(atCap ? .capReached(elapsed: t) : .inputLost(elapsed: t))
    }

    private func sessionChanged(_ change: SessionChange) {
        let t = max(elapsed, recorder.elapsed)
        switch change {
        case .interruptionBegan: send(.interruptionBegan(elapsed: t))
        case .mediaServicesReset: send(.mediaServicesReset(elapsed: t))
        case .routeChanged(let available): send(.routeChanged(inputAvailable: available, elapsed: t))
        }
    }

    // MARK: Encode, send, hold, discard

    private func item(_ stem: String) async -> OutboxItem? {
        if let i = items[stem] { return i }
        let found = (try? await outbox.items())?.first { $0.stem == stem }
        items[stem] = found
        return found
    }

    private func encode(_ stem: String) async {
        guard var item = await item(stem) else {
            send(.encodeFailed(stem: stem, "its folder is gone from the outbox"))
            return
        }
        beginBackgroundIfNeeded()
        // A note whose sidecar exists was encoded and checked before (a resend, or a send cut off).
        let names = (try? await outbox.fs.list(item.folder)) ?? []
        if names.contains(item.sidecarName), names.contains(item.audioName), await audio.isWhole(item.m4aURL) {
            send(.encodeFinished(stem: stem))
            return
        }
        do {
            if names.contains(item.audioName) { try await outbox.fs.remove(item.m4aURL) }
            let encoded = try await audio.encode(item.cafURL, item.m4aURL)
            Self.excludeFromBackup(item.m4aURL)
            let sidecar = Sidecar(audioFile: item.audioName, captureID: item.captureID,
                                  spokenAt: SpokenAt.string(item.state.created_at, zone: zone()),
                                  bytes: encoded.bytes, selfOnly: true, test: settings.markAsTest,
                                  durationSeconds: encoded.seconds)
            try await outbox.fs.write(try sidecar.encoded(), to: item.sidecarURL)
            item.state.held_reason = nil
            try await outbox.save(item)
            items[stem] = item
            send(.encodeFinished(stem: stem))
        } catch {
            send(.encodeFailed(stem: stem, error.localizedDescription))
        }
    }

    private func deliver(_ stem: String) async {
        guard let item = await item(stem) else {
            send(.sendFailed(stem: stem, "its folder is gone from the outbox"))
            return
        }
        beginBackgroundIfNeeded()
        let delivery = Delivery(fs: inboxFS, abort: abort)
        do {
            let result = try await folders.withAccess(.inbox) { inbox in
                try await delivery.sendAudio(item, inbox: inbox)
            }
            switch result {
            case .sent, .alreadyThere:
                items[stem] = try await outbox.markSent(item, at: now())
                folderProblem = nil
                send(.sendFinished(stem: stem))
            case .unknown:
                send(.sendFailed(stem: stem, "the inbox could not be listed, it will be tried again"))
            }
        } catch let e as FolderAccessError {
            folderProblem = .inbox
            send(.sendFailed(stem: stem, e.localizedDescription))
        } catch {
            send(.sendFailed(stem: stem, error.localizedDescription))
        }
        await refresh()
    }

    private func hold(_ stem: String, _ reason: HoldReason) async {
        guard let item = await item(stem) else { return }
        items[stem] = try? await outbox.hold(item, reason)
        await refresh()
    }

    private func discard(_ stem: String) async {
        if let item = await item(stem) { try? await outbox.remove(item) }
        items[stem] = nil
        await refresh()
    }

    // MARK: Text notes

    /// Sends a text note into the top of the inbox (F70). The microphone is never touched here.
    /// Returns false when nothing was sent, with the reason in `message`.
    func sendText(_ text: String) async -> Bool {
        let at = now()
        let tz = zone()
        let delivery = Delivery(fs: inboxFS)
        do {
            let name = try await folders.withAccess(.inbox) { inbox in
                try await delivery.sendTextNote(text, at: at, zone: tz, suffix: CaptureNaming.randomSuffix(), inbox: inbox)
            }
            guard let name else {
                message = "Nothing to send"
                return false
            }
            settings.sentTexts.append(SentText(name: name, sentAt: at))
            folderProblem = nil
            message = "Text note sent"
            await refresh()
            return true
        } catch let e as FolderAccessError {
            folderProblem = .inbox
            message = e.localizedDescription
        } catch {
            message = "Not sent: \(error.localizedDescription)"
        }
        return false
    }

    // MARK: Launch

    /// Salvage, clean-up, retention and the install marker (plan `## Stage 5`, F17, F42, F45, F67).
    /// Nothing here touches the microphone or the audio session (F76).
    func launch() async {
        expiry = expiryDate()
        showExpiryBanner = ExpiryReminder.showBanner(expiry: expiry, now: now())
        let all = (try? await outbox.items()) ?? []
        for i in all { items[i.stem] = i }
        if folders.state(.inbox) != .notPicked {
            await removeOwnParts(all)
            await writeInstallMarker()
        }
        await applyRetention()
        // A note the machine already holds (recording now after a cold start from the Shortcut,
        // or queued by the launch before onboarding finished) is not found a second time.
        for i in all where i.sentAt == nil && !machineHolds(i.stem) {
            let names = (try? await outbox.fs.list(i.folder)) ?? []
            let encoded = names.contains(i.sidecarName) && names.contains(i.audioName)
            if !encoded && !names.contains(i.stem + ".caf") { continue }
            let voiced = encoded ? true : await audio.heardVoice(i.cafURL)
            send(.launchFoundLeftover(stem: i.stem, heardVoice: voiced))
        }
        send(.enteredForeground)
        await refresh()
    }

    /// A copy cut off by a kill leaves `.<name>.part` files, which the Mac ignores. Only the app's
    /// own are removed: the parts of its outbox notes, and `.dictation-*.txt.part` (F42).
    private func removeOwnParts(_ all: [OutboxItem]) async {
        let fs = inboxFS
        let own = Set(all.flatMap { [Delivery.partName($0.audioName), Delivery.partName($0.sidecarName)] })
        _ = try? await folders.withAccess(.inbox) { inbox in
            let audioDir = inbox.appendingPathComponent("audio", isDirectory: true)
            for name in (try? await fs.list(audioDir)) ?? [] where own.contains(name) {
                try? await fs.remove(audioDir.appendingPathComponent(name))
            }
            for name in (try? await fs.list(inbox)) ?? [] where name.hasPrefix(".dictation-") && name.hasSuffix(".txt.part") {
                try? await fs.remove(inbox.appendingPathComponent(name))
            }
        }
    }

    static let installMarkerName = "lt-capture-install.txt"

    /// `audio/lt-capture-install.txt`, written once per new profile expiry date (F67).
    private func writeInstallMarker() async {
        guard let expiry, settings.installMarkerExpiry != expiry else { return }
        let fs = inboxFS
        let text = ProvisioningExpiry.installMarker(expiry: expiry, installedAt: now(), version: AppInfo.version)
        do {
            try await folders.withAccess(.inbox) { inbox in
                let audioDir = inbox.appendingPathComponent("audio", isDirectory: true)
                try await fs.createDirectory(audioDir)
                try await fs.write(Data(text.utf8), to: audioDir.appendingPathComponent(Self.installMarkerName))
            }
            settings.installMarkerExpiry = expiry
        } catch {
            // Tried again on the next launch.
        }
    }

    /// Deletes the phone's copy only where `Retention` allows it (F32, F45).
    private func applyRetention() async {
        let receipt = await readReceipt()
        let r: Receipt? = if case .read(let r) = receipt { r } else { nil }
        for (stem, item) in items where item.sentAt != nil {
            let entry = r.flatMap { ReceiptMatcher.entry(name: item.audioName, captureID: item.captureID, in: $0) }
            guard Retention.canDelete(item, entry: entry, now: now()) else { continue }
            if (try? await outbox.remove(item)) != nil { items[stem] = nil }
        }
        let cutoff = now().addingTimeInterval(-TimeInterval(Retention.keepDays * 24 * 3600))
        settings.sentTexts.removeAll { $0.sentAt < cutoff }
    }

    // MARK: Status

    private func readReceipt() async -> ReceiptState {
        guard folders.state(.out) != .notPicked else { return .notPicked }
        let fs = inboxFS
        do {
            return try await folders.withAccess(.out) { out in await ReceiptReader.load(fs: fs, outFolder: out) }
        } catch {
            return .unreadable
        }
    }

    /// After any pick: clears "Pick the folder again" once the stored bookmark is usable, then
    /// rereads the receipt and listings.
    func folderPicked(_ folder: CaptureFolder) async {
        if folderProblem == folder, folders.state(folder).canUse { folderProblem = nil }
        await refresh()
    }

    /// Reads the receipt and the two listings once, then words every row (plan `### Status words`).
    func refresh() async {
        let receiptState = await readReceipt()
        let receipt: Receipt? = if case .read(let r) = receiptState { r } else { nil }
        var audioNames: [String]?
        var processedNames: [String]?
        var upload: [String: String] = [:]
        let sentItems = items.values.filter { $0.sentAt != nil }
        if !sentItems.isEmpty, folders.state(.inbox) != .notPicked {
            let fs = inboxFS
            let words = uploadWords
            _ = try? await folders.withAccess(.inbox) { inbox in
                let audioDir = inbox.appendingPathComponent("audio", isDirectory: true)
                audioNames = try? await fs.list(audioDir)
                processedNames = (try? await fs.list(audioDir.appendingPathComponent("processed", isDirectory: true))) ?? (audioNames == nil ? nil : [])
                for i in sentItems where audioNames?.contains(i.audioName) == true {
                    upload[i.stem] = words(audioDir.appendingPathComponent(i.audioName))
                }
            }
        }

        var out: [StatusItem] = []
        let t = now()
        for item in items.values {
            if item.stem == recordingItem?.stem { continue }
            let entry = receipt.flatMap { ReceiptMatcher.entry(name: item.audioName, captureID: item.captureID, in: $0) }
            let placement = ResendGuard.placement(name: item.audioName, audioListing: audioNames, processedListing: processedNames)
            let status = StatusResolver.status(item, entry: entry, placement: placement, receiptState: receiptState, now: t)
            let decision = ResendGuard.decision(name: item.audioName, audioListing: audioNames, processedListing: processedNames)
            out.append(StatusItem(
                id: item.stem, kind: .voice, when: item.state.created_at,
                words: status.words(upload: upload[item.stem]),
                canResend: item.sentAt != nil && StatusResolver.offersResend(entry: entry, decision: decision),
                askDiscard: askDiscard.contains(item.stem)))
        }
        for text in settings.sentTexts {
            let entry = receipt.flatMap { ReceiptMatcher.entry(name: text.name, captureID: nil, in: $0) }
            let status = StatusResolver.textStatus(sentAt: text.sentAt, entry: entry, receiptState: receiptState, now: t)
            out.append(StatusItem(id: text.name, kind: .text, when: text.sentAt, words: status.words,
                                  canResend: false, askDiscard: false))
        }
        rows = out.sorted { $0.when > $1.when }
    }

    // MARK: Plumbing

    private func machineHolds(_ stem: String) -> Bool {
        if stem == recordingItem?.stem || machine.queue.contains(stem) || machine.askPending.contains(stem) { return true }
        switch machine.state {
        case .recording(let s), .encoding(let s), .sending(let s): return s == stem
        case .idle, .starting: return false
        }
    }

    /// Runs file work one piece at a time, in the order the machine asked for it.
    private func enqueueWork(_ op: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { await previous?.value; await op() }
    }

    /// Waits until every queued piece of file work has finished. For the tests and the intent.
    func settle() async {
        while let w = work {
            await w.value
            if work == w { return }
        }
    }

    private func beginBackgroundIfNeeded() {
        guard background == nil else { return }
        abort = AbortFlag()
        background = beginBackground(abort) { [weak self] in
            self?.background = nil
            self?.send(.backgroundTimeExpired)
        }
    }

    private func endBackgroundIfIdle() {
        guard machine.state == .idle, machine.queue.isEmpty, let b = background else { return }
        // The send's own refresh may still be queued, so the task ends once the work drains.
        let last = work
        Task {
            await last?.value
            guard self.machine.state == .idle, self.background === b else { return }
            b.end()
            self.background = nil
        }
    }

    nonisolated static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }
}
