import Foundation

/// Where host tests keep what they write, so `scripts/check_artefacts.sh` can run the Mac's own
/// checks on it (plan `## Stage 2`, F12).
///
/// `verify.sh` step 1 sets `LTCAP_ARTEFACTS` to a fresh `build/host-artefacts/run-<timestamp>/`.
/// Each artefact gets its own `<artefact>.entry.json` beside it, because Swift Testing runs tests
/// in parallel and one shared manifest would race. Without the variable the files go to a new
/// temporary folder and no entry is written.
nonisolated enum Artefacts {
    static let fromVerify: Bool = ProcessInfo.processInfo.environment["LTCAP_ARTEFACTS"].map { !$0.isEmpty } ?? false

    static let root: URL = {
        let dir: URL
        if let env = ProcessInfo.processInfo.environment["LTCAP_ARTEFACTS"], !env.isEmpty {
            dir = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltcap-artefacts-\(UUID().uuidString)")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// Writes `<name>.entry.json`. `path` is relative to `build/host-artefacts`, so it starts with the run folder.
    static func record(_ name: String, kind: String, expect: String, test: String, bytes: Int? = nil,
                       durationMin: Double? = nil, durationMax: Double? = nil, kbps: Double? = nil) throws {
        guard fromVerify else { return }
        var entry: [String: Any] = ["path": root.lastPathComponent + "/" + name, "kind": kind,
                                    "expect": expect, "test": test]
        if let bytes { entry["bytes"] = bytes }
        if let durationMin { entry["duration_min"] = durationMin }
        if let durationMax { entry["duration_max"] = durationMax }
        if let kbps { entry["kbps"] = (kbps * 10).rounded() / 10 }
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        try data.write(to: url(name + ".entry.json"))
    }

    static func size(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? -1
    }
}
