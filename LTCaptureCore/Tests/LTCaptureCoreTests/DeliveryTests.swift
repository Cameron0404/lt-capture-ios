import Foundation
import Testing
@testable import LTCaptureCore

/// The outbox, the copy into `audio/`, resend safety and text notes (plan `## Stage 4`,
/// F23, F42, F46, F58, F64, F74, F80).
struct DeliveryTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    func setUp(_ label: String) -> (outbox: Outbox, inbox: URL, fs: RecordingFileSystem) {
        let base = tempFolder(label)
        let inbox = base.appendingPathComponent("life-tracker-inbox", isDirectory: true)
        try! FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let outbox = Outbox(root: base.appendingPathComponent("Outbox", isDirectory: true),
                            fs: LocalFileSystem(excludeFromBackup: true))
        return (outbox, inbox, RecordingFileSystem())
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func firstSendCreatesAudioAndRunsTheStepsInOrder() async throws {
        let (outbox, inbox, fs) = setUp("first")
        let item = try await makeOutboxItem(outbox)
        #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("audio").path))

        let result = try await Delivery(fs: fs).sendAudio(item, inbox: inbox)

        #expect(result == .sent)
        let stem = item.stem
        #expect(fs.events == [
            "mkdir audio",
            "copy .\(stem).m4a.part",
            "write .\(stem).json.part",
            "move .\(stem).m4a.part -> \(stem).m4a",
            "move .\(stem).json.part -> \(stem).json",
            "size \(stem).m4a",
        ])
        let audio = inbox.appendingPathComponent("audio")
        #expect(names(audio) == ["\(stem).json", "\(stem).m4a"])
        #expect(try Data(contentsOf: audio.appendingPathComponent(item.audioName)) == Data(contentsOf: item.m4aURL))
        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: audio.appendingPathComponent(item.sidecarName))) as! [String: Any]
        #expect(sidecar["bytes"] as? Int == 300_000)
    }

    @Test func aFinalNameThatExistsIsNeverOverwritten() async throws {
        // The file system refuses outright.
        let dir = tempFolder("exists")
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try Data("new".utf8).write(to: a)
        try Data("old".utf8).write(to: b)
        await #expect(throws: CaptureFSError.exists("b")) { try await LocalFileSystem().move(a, to: b) }
        #expect(try String(contentsOf: b, encoding: .utf8) == "old")

        // And through a send: a stray sidecar with our name in `audio/` stays as it was.
        let (outbox, inbox, fs) = setUp("exists-send")
        let item = try await makeOutboxItem(outbox)
        let audio = inbox.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio.appendingPathComponent("processed"), withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: audio.appendingPathComponent(item.sidecarName))
        await #expect(throws: CaptureFSError.exists(item.sidecarName)) { try await Delivery(fs: fs).sendAudio(item, inbox: inbox) }
        #expect(try String(contentsOf: audio.appendingPathComponent(item.sidecarName), encoding: .utf8) == "someone else's")
    }

    @Test func killedAfterTheCopyBeforeSentAtThenRelaunchSendsNothing() async throws {
        let (outbox, inbox, fs) = setUp("killed")
        let item = try await makeOutboxItem(outbox)
        #expect(try await Delivery(fs: fs).sendAudio(item, inbox: inbox) == .sent)
        // Killed here: `markSent` never ran, so the outbox still says not sent.
        let relaunched = try #require(try await outbox.items().first)
        #expect(relaunched.sentAt == nil)

        let again = RecordingFileSystem()
        #expect(try await Delivery(fs: again).sendAudio(relaunched, inbox: inbox) == .alreadyThere)
        #expect(again.events.isEmpty)
        #expect(names(inbox.appendingPathComponent("audio")) == ["\(item.stem).json", "\(item.stem).m4a"])

        // The same once the Mac has moved it into `audio/processed/`.
        let audio = inbox.appendingPathComponent("audio")
        let processed = audio.appendingPathComponent("processed")
        try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio.appendingPathComponent(item.audioName), to: processed.appendingPathComponent(item.audioName))
        #expect(try await Delivery(fs: again).sendAudio(relaunched, inbox: inbox) == .alreadyThere)
        #expect(again.events.isEmpty)

        let sent = try await outbox.markSent(relaunched, at: now)
        #expect(try await outbox.items().first?.sentAt == sent.sentAt)
    }

    @Test func abortMidCopyLeavesOnlyThePartAndTheNextLaunchSendsAgain() async throws {
        let (outbox, inbox, _) = setUp("abort")
        let item = try await makeOutboxItem(outbox, bytes: 300_000)
        let flag = AbortFlag()
        let fs = RecordingFileSystem(LocalFileSystem(chunkBytes: 64 * 1024, onChunk: { total in
            if total >= 64 * 1024 { flag.abort() }
        }))
        await #expect(throws: CaptureFSError.aborted) { try await Delivery(fs: fs, abort: flag).sendAudio(item, inbox: inbox) }

        let audio = inbox.appendingPathComponent("audio")
        let part = ".\(item.stem).m4a.part"
        #expect(names(audio) == [part])
        let partBytes = try FileManager.default.attributesOfItem(atPath: audio.appendingPathComponent(part).path)[.size] as! Int
        #expect(partBytes > 0 && partBytes < 300_000)

        // Next launch: the Mac has run meanwhile, so `audio/` also holds `processed/`.
        try FileManager.default.createDirectory(at: audio.appendingPathComponent("processed"), withIntermediateDirectories: true)
        let next = RecordingFileSystem()
        #expect(try await Delivery(fs: next).sendAudio(item, inbox: inbox) == .sent)
        #expect(next.events.first == "remove \(part)")
        #expect(names(audio) == ["\(item.stem).json", "\(item.stem).m4a", "processed"])
    }

    @Test func anEmptyOrFailedListingIsUnknownAndCopiesNothing() async throws {
        let (outbox, inbox, fs) = setUp("unknown")
        let item = try await makeOutboxItem(outbox)
        let audio = inbox.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        #expect(try await Delivery(fs: fs).sendAudio(item, inbox: inbox) == .unknown)

        try FileManager.default.createDirectory(at: audio.appendingPathComponent("processed"), withIntermediateDirectories: true)
        fs.failListing = "processed"
        #expect(try await Delivery(fs: fs).sendAudio(item, inbox: inbox) == .unknown)
        fs.failListing = "audio"
        #expect(try await Delivery(fs: fs).sendAudio(item, inbox: inbox) == .unknown)
        #expect(fs.events.isEmpty)
        #expect(names(audio) == ["processed"])
    }

    @Test func aSizeThatDisagreesWithTheSidecarIsAnError() async throws {
        let (outbox, inbox, fs) = setUp("size")
        let item = try await makeOutboxItem(outbox, bytes: 1000, sidecarBytes: 999)
        await #expect(throws: CaptureFSError.sizeMismatch(expected: 999, got: 1000)) {
            try await Delivery(fs: fs).sendAudio(item, inbox: inbox)
        }
    }

    @Test func resendGuardCountsPlaceholdersAndNeverSendsOnUnknown() {
        let n = "2026-10-12-073015-4821.m4a"
        #expect(ResendGuard.decision(name: n, audioListing: ["processed", ".\(n).icloud"], processedListing: []) == .alreadyThere)
        #expect(ResendGuard.decision(name: n, audioListing: ["processed"], processedListing: [".\(n).icloud"]) == .alreadyThere)
        #expect(ResendGuard.decision(name: n, audioListing: ["processed", n], processedListing: nil) == .alreadyThere)
        #expect(ResendGuard.decision(name: n, audioListing: nil, processedListing: []) == .unknown)
        #expect(ResendGuard.decision(name: n, audioListing: [], processedListing: []) == .unknown)
        #expect(ResendGuard.decision(name: n, audioListing: ["processed"], processedListing: nil) == .unknown)
        #expect(ResendGuard.decision(name: n, audioListing: ["processed", "other.m4a"], processedListing: []) == .send)
        // A name that only starts like ours is not ours.
        #expect(ResendGuard.decision(name: n, audioListing: ["processed", "2026-10-12-073015-4821-2.m4a"], processedListing: []) == .send)
        #expect(ResendGuard.placement(name: n, audioListing: ["processed"], processedListing: [n]) == .inProcessed)
        #expect(ResendGuard.placement(name: n, audioListing: ["processed"], processedListing: []) == .absent)
    }

    @Test func aTextNoteLandsInTheTopFolderThroughAPartRename() async throws {
        let (_, inbox, fs) = setUp("text")
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let london = TimeZone(identifier: "Europe/London")!
        let name = try #require(try await Delivery(fs: fs).sendTextNote("  Buy café beans \n", at: at, zone: london, suffix: 7, inbox: inbox))
        let stem = CaptureNaming.stem(start: at, zone: london, suffix: 7)
        #expect(name == "dictation-\(stem).txt")
        #expect(fs.events == ["write .\(name).part", "move .\(name).part -> \(name)"])
        #expect(names(inbox) == [name])
        let body = try String(contentsOf: inbox.appendingPathComponent(name), encoding: .utf8)
        #expect(body == TextNote.body("Buy café beans", at: at))
        #expect(body.hasPrefix(HeaderTime.string(at) + "\n\n"))
    }

    @Test func emptyTextIsNeverSent() async throws {
        let (_, inbox, fs) = setUp("empty")
        for text in ["", "   ", "\n\t \n"] {
            #expect(try await Delivery(fs: fs).sendTextNote(text, at: now, zone: .current, suffix: 1, inbox: inbox) == nil)
        }
        #expect(fs.events.isEmpty)
        #expect(names(inbox).isEmpty)
    }

    @MainActor
    @Test func theCopyRunsOffTheMainThread() async throws {
        #expect(onMainThread())
        let (outbox, inbox, fs) = setUp("thread")
        let item = try await makeOutboxItem(outbox)
        #expect(try await Delivery(fs: fs).sendAudio(item, inbox: inbox) == .sent)
        #expect(fs.events.contains("copy .\(item.stem).m4a.part"))
        #expect(fs.mainThreadCalls.isEmpty)
    }

    @Test func theOutboxKeepsStateAndIsExcludedFromBackup() async throws {
        let (outbox, _, _) = setUp("outbox")
        let item = try await makeOutboxItem(outbox)
        let held = try await outbox.hold(item, .nothingHeard)
        let items = try await outbox.items()
        #expect(items == [held])
        #expect(items.first?.heldReason == .nothingHeard)
        for u in [item.folder, item.stateURL, item.m4aURL, item.sidecarURL] {
            #expect(isMarkedExcludedFromBackup(u), "\(u.lastPathComponent)")
        }
        // A `.caf` with no `.m4a` is a leftover for the salvage on launch.
        #expect(try await outbox.leftovers().isEmpty)
        let other = try await outbox.create(stem: "2026-10-12-080000-0001", captureID: "X", now: now.addingTimeInterval(60))
        try Data([0, 1]).write(to: other.cafURL)
        #expect(try await outbox.leftovers().map(\.stem) == [other.stem])
    }
}
