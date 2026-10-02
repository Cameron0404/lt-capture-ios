import Foundation

/// Why a recording ended. The first three come from the person, the recorder or the system, the
/// silence ones from `SilenceDetector` (plan `### Stop policy`, F33, F40, F41, F66).
public nonisolated enum StopReason: String, Sendable, Equatable, Codable {
    case button
    case shortcut
    case cap
    case interruption
    case mediaServicesReset
    case inputLost
    /// Armed by at least 3 s of voice, then 20 s with none.
    case silence
    /// Some voice, too little to arm, then 10 s with none (F66).
    case unarmedQuiet
    /// No voiced tick at all in the first 30 s. The note is held and the owner is asked (F41).
    case nothingHeard
}

public nonisolated enum SilenceEvent: Sendable, Equatable {
    /// 15 s without voice while armed. The app plays a haptic, in the foreground only (F73).
    case warn
    case stop(StopReason)
}

/// The numbers of the stop policy, in seconds and dB. `standard` is the plan's.
public nonisolated struct SilenceConfig: Sendable, Equatable {
    /// The Settings toggle "Stop after silence". Off means the detector never stops a note.
    public var enabled: Bool
    public var tick: TimeInterval
    public var voicedAboveFloorDB: Float
    public var voicedMinDB: Float
    public var floorRiseDBPerSecond: Float
    public var armAfterVoicedSeconds: TimeInterval
    public var armNotBeforeSeconds: TimeInterval
    public var armedStopSeconds: TimeInterval
    public var armedWarnSeconds: TimeInterval
    public var unarmedStopSeconds: TimeInterval
    public var nothingHeardStopSeconds: TimeInterval

    public init(enabled: Bool = true, tick: TimeInterval = 0.05, voicedAboveFloorDB: Float = 10, voicedMinDB: Float = -55,
                floorRiseDBPerSecond: Float = 1, armAfterVoicedSeconds: TimeInterval = 3, armNotBeforeSeconds: TimeInterval = 5,
                armedStopSeconds: TimeInterval = 20, armedWarnSeconds: TimeInterval = 15, unarmedStopSeconds: TimeInterval = 10,
                nothingHeardStopSeconds: TimeInterval = 30) {
        self.enabled = enabled
        self.tick = tick
        self.voicedAboveFloorDB = voicedAboveFloorDB
        self.voicedMinDB = voicedMinDB
        self.floorRiseDBPerSecond = floorRiseDBPerSecond
        self.armAfterVoicedSeconds = armAfterVoicedSeconds
        self.armNotBeforeSeconds = armNotBeforeSeconds
        self.armedStopSeconds = armedStopSeconds
        self.armedWarnSeconds = armedWarnSeconds
        self.unarmedStopSeconds = unarmedStopSeconds
        self.nothingHeardStopSeconds = nothingHeardStopSeconds
    }

    public static let standard = SilenceConfig()
}

/// Decides from levels alone when a note has gone quiet (plan `### Stop policy`).
///
/// A tick is voiced when it is at least 10 dB above an adaptive floor and above -55 dBFS. The floor
/// drops at once to any quieter tick and rises at most 1 dB a second, so a steady fan becomes the
/// floor instead of counting as voice for ever. The detector arms on a voiced tick once 3 s of voice
/// have been heard and 5 s have passed, so speech wholly inside the first 5 s never arms it. Levels
/// cannot tell the owner's voice from anyone else's (F66): babble keeps a note going, which the README says.
public nonisolated struct SilenceDetector: Sendable {
    public let config: SilenceConfig
    public private(set) var floorDB: Float?
    public private(set) var voicedSeconds: TimeInterval = 0
    public private(set) var lastVoicedAt: TimeInterval?
    public private(set) var armed = false
    public private(set) var stopped: StopReason?
    private var lastTickAt: TimeInterval?
    private var warned = false

    public init(_ config: SilenceConfig = .standard) { self.config = config }

    /// Whether any tick so far was voiced, the salvage path's "any voice?" check.
    public var heardVoice: Bool { lastVoicedAt != nil }

    /// Feeds one level, `at` seconds after the recording started. Returns at most one event, and
    /// nothing at all once a stop has been returned.
    public mutating func feed(dB raw: Float, at t: TimeInterval, foreground: Bool) -> SilenceEvent? {
        guard stopped == nil else { return nil }
        let dB = raw.isNaN ? LevelMeter.silenceDB : max(LevelMeter.silenceDB, min(0, raw))
        let dt = lastTickAt.map { max(0, t - $0) } ?? config.tick
        lastTickAt = t

        if let floor = floorDB {
            floorDB = min(dB, floor + config.floorRiseDBPerSecond * Float(dt))
        } else {
            floorDB = dB
        }
        let voiced = dB > floorDB! + config.voicedAboveFloorDB && dB > config.voicedMinDB
        if voiced {
            voicedSeconds += dt
            lastVoicedAt = t
            warned = false
            if !armed && voicedSeconds >= config.armAfterVoicedSeconds && t >= config.armNotBeforeSeconds {
                armed = true
            }
        }
        guard config.enabled else { return nil }

        guard let last = lastVoicedAt else {
            return t >= config.nothingHeardStopSeconds ? stop(.nothingHeard) : nil
        }
        let quiet = t - last
        if armed {
            if quiet >= config.armedStopSeconds { return stop(.silence) }
            if quiet >= config.armedWarnSeconds && foreground && !warned {
                warned = true
                return .warn
            }
            return nil
        }
        return quiet >= config.unarmedStopSeconds ? stop(.unarmedQuiet) : nil
    }

    private mutating func stop(_ r: StopReason) -> SilenceEvent {
        stopped = r
        return .stop(r)
    }

    /// What the detector decides on a whole run of ticks, `tick` seconds apart from time 0.
    public nonisolated struct Decision: Sendable, Equatable {
        public var stop: StopReason?
        /// Seconds from the start of the note to the tick that stopped it.
        public var stoppedAt: TimeInterval?
        public var heardVoice: Bool
        public var warnings: Int
    }

    /// Runs `ticks` through a fresh detector in the background (no haptic), for offline levels
    /// from `LevelMeter.ticks` and for test traces, so both take the same path.
    public static func decide(_ ticks: [Float], config: SilenceConfig = .standard, foreground: Bool = false) -> Decision {
        var d = SilenceDetector(config)
        var warnings = 0
        for (i, dB) in ticks.enumerated() {
            let t = Double(i + 1) * config.tick
            switch d.feed(dB: dB, at: t, foreground: foreground) {
            case .warn?: warnings += 1
            case .stop(let r)?: return Decision(stop: r, stoppedAt: t, heardVoice: d.heardVoice, warnings: warnings)
            case nil: break
            }
        }
        return Decision(stop: nil, stoppedAt: nil, heardVoice: d.heardVoice, warnings: warnings)
    }
}
