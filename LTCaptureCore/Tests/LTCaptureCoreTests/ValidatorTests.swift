import Foundation
import Testing
@testable import LTCaptureCore

/// The phone refuses a bad `.m4a` before it copies anything (plan `## Stage 2`, F65).
struct ValidatorTests {
    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func unclosedFileIsRefused() throws {
        let caf = try Synth.caf([.tone(seconds: 3)], name: "unclosed")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ltcap-unclosed-\(UUID().uuidString).m4a")
        let (writer, frames) = try Encoder.write(caf: caf, to: work, settings: .standard)
        #expect(frames == 3 * 24000)
        // Copy the bytes while the writer is still open: once it is released it would finish the file.
        let artefact = Artefacts.url("unclosed-3s.m4a")
        try Data(contentsOf: work).write(to: artefact)
        #expect(throws: M4AError.self) { try M4AValidator.validate(work, capSeconds: 600) }
        #expect(throws: M4AError.self) { try M4AValidator.validate(artefact, capSeconds: 600) }
        try Artefacts.record("unclosed-3s.m4a", kind: "m4a", expect: "fail", test: "unclosedFileIsRefused",
                             bytes: try Artefacts.size(artefact))
        writer.close()
        // The same writer, closed, is a good file: the close is what the check depends on.
        #expect(try M4AValidator.validate(work, capSeconds: 600).frames > 0)
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func truncatedFileIsRefused() async throws {
        let caf = try Synth.caf([.tone(seconds: 5)], name: "cut")
        let whole = FileManager.default.temporaryDirectory.appendingPathComponent("ltcap-whole-\(UUID().uuidString).m4a")
        _ = try await Encoder.encode(caf: caf, to: whole, settings: .standard)
        let data = try Data(contentsOf: whole)
        let cut = Artefacts.url("truncated-5s.m4a")
        try data.prefix(data.count - 1000).write(to: cut)
        #expect(throws: M4AError.self) { try M4AValidator.validate(cut, capSeconds: 600) }
        try Artefacts.record("truncated-5s.m4a", kind: "m4a", expect: "fail", test: "truncatedFileIsRefused",
                             bytes: try Artefacts.size(cut))
    }

    @Test(.enabled(if: Codecs.aacReachable, "needs the AAC codec")) func overTheCapIsRefused() async throws {
        let caf = try Synth.caf([.tone(seconds: 7)], name: "long")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ltcap-long-\(UUID().uuidString).m4a")
        _ = try await Encoder.encode(caf: caf, to: out, settings: .standard)
        #expect(throws: M4AError.self) { try M4AValidator.validate(out, capSeconds: 5) }
        #expect(try M4AValidator.validate(out, capSeconds: 7.1).durationSeconds > 6.9)
    }

    @Test func fragmentedAndMissingBoxesAreRefused() throws {
        func box(_ type: String, _ body: Data = Data()) -> Data {
            var d = Data()
            let size = UInt32(8 + body.count).bigEndian
            withUnsafeBytes(of: size) { d.append(contentsOf: $0) }
            d.append(contentsOf: Array(type.utf8))
            d.append(body)
            return d
        }
        let dir = FileManager.default.temporaryDirectory
        let fragmented = dir.appendingPathComponent("ltcap-frag-\(UUID().uuidString).m4a")
        try (box("ftyp", Data("M4A ".utf8)) + box("moov", box("mvex")) + box("moof") + box("mdat", Data([1, 2, 3])))
            .write(to: fragmented)
        #expect(throws: M4AError.fragmented) { try M4AValidator.validate(fragmented, capSeconds: 600) }

        let noMoov = dir.appendingPathComponent("ltcap-nomoov-\(UUID().uuidString).m4a")
        try (box("ftyp", Data("M4A ".utf8)) + box("mdat", Data([1, 2, 3]))).write(to: noMoov)
        #expect(throws: M4AError.missing("moov")) { try M4AValidator.validate(noMoov, capSeconds: 600) }

        // The Mac's m4acheck.py must refuse both too. These need no codec, so the manifest always
        // holds files the Mac should fail, even where the encode tests cannot run.
        for (name, url) in [("fragmented.m4a", fragmented), ("no-moov.m4a", noMoov)] {
            try Data(contentsOf: url).write(to: Artefacts.url(name))
            try Artefacts.record(name, kind: "m4a", expect: "fail", test: "fragmentedAndMissingBoxesAreRefused",
                                 bytes: try Artefacts.size(url))
        }
    }
}
