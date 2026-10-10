import Foundation

/// Pure state machine that decides, tick by tick, whether the app-audio process
/// tap is healthy for the whole recording, not just its first seconds. Exposed
/// for unit tests; `RecordingManager` feeds it once per tick and applies the actions.
///
/// Why it exists: on macOS 26 a tap that lost (or never had) the System Audio
/// grant still returns `noErr` and keeps firing callbacks — it just delivers
/// all-zero samples, sometimes only partway through a long session. Silence alone
/// is ambiguous (nobody talking, everyone muted, waiting in a lobby), so the
/// monitor only counts silence while the meeting app is actually rendering
/// output, rebuilds the tap before warning, and clears the warning the moment
/// audio returns.
public struct AppAudioHealthMonitor: Equatable {
    public enum Action: Equatable {
        /// Tear down and rebuild with a fresh WAV. Startup only — catches helper
        /// processes that opened audio after the initial process enumeration.
        case rebuildFresh
        /// Tear down and rebuild the tap chain, appending to the existing WAV so
        /// audio already captured (and the mic/app alignment) is kept.
        case rebuildPreservingFile
        /// Sustained digital silence while the meeting app is playing audio.
        case flagSilent
        /// Audio is flowing again after a `flagSilent`.
        case clearFlag
        /// First non-zero app audio of the recording — the System Audio grant works.
        case confirmCapture
    }

    public struct Config: Equatable {
        public var startupCheckSeconds: Double = 2
        public var silenceRebuildSeconds: Double = 30
        public var silenceWarnSeconds: Double = 60
        public var deadCallbackRebuildSeconds: Double = 10
        public var maxRebuilds: Int = 4
        public init() {}
    }

    public let config: Config
    public private(set) var elapsed: Double = 0
    public private(set) var silentSeconds: Double = 0
    public private(set) var deadCallbackSeconds: Double = 0
    public private(set) var heardAudio = false
    public private(set) var isFlagged = false
    public private(set) var startupCheckDone = false
    public private(set) var rebuiltThisSilentStretch = false
    public private(set) var rebuildCount = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// True when the tap has delivered only zeros while the meeting app was
    /// rendering audio for the whole recording so far — the signature of a denied
    /// System Audio grant.
    public var looksLikePermissionDenied: Bool { isFlagged && !heardAudio }

    /// Feed one tick of observations.
    /// - Parameters:
    ///   - seconds: time since the previous tick.
    ///   - receivedAudio: any non-zero sample arrived since the previous tick.
    ///   - callbacksFiring: the IOProc ran at least once since the previous tick.
    ///   - meetingAppOutputActive: the meeting app has an output stream running
    ///     (pass `true` when unknown, so the monitor falls back to time alone).
    public mutating func tick(
        seconds: Double,
        receivedAudio: Bool,
        callbacksFiring: Bool,
        meetingAppOutputActive: Bool
    ) -> [Action] {
        elapsed += seconds
        var actions: [Action] = []

        if receivedAudio {
            silentSeconds = 0
            deadCallbackSeconds = 0
            rebuiltThisSilentStretch = false
            if !heardAudio {
                heardAudio = true
                actions.append(.confirmCapture)
            }
            if isFlagged {
                isFlagged = false
                actions.append(.clearFlag)
            }
            return actions
        }

        // One fast rebuild early on, before any audio has ever arrived.
        if !startupCheckDone && elapsed >= config.startupCheckSeconds {
            startupCheckDone = true
            if !heardAudio {
                return [.rebuildFresh]
            }
        }

        deadCallbackSeconds = callbacksFiring ? 0 : deadCallbackSeconds + seconds
        if meetingAppOutputActive || !callbacksFiring {
            silentSeconds += seconds
        }

        let canRebuild = rebuildCount < config.maxRebuilds
        if canRebuild && deadCallbackSeconds >= config.deadCallbackRebuildSeconds {
            // Callbacks stopped entirely — the aggregate is dead regardless of
            // what the meeting app is doing.
            deadCallbackSeconds = 0
            rebuildCount += 1
            actions.append(.rebuildPreservingFile)
        } else if canRebuild && !rebuiltThisSilentStretch && silentSeconds >= config.silenceRebuildSeconds {
            rebuiltThisSilentStretch = true
            rebuildCount += 1
            actions.append(.rebuildPreservingFile)
        }

        if !isFlagged && silentSeconds >= config.silenceWarnSeconds {
            isFlagged = true
            actions.append(.flagSilent)
        }
        return actions
    }

    /// Call after a rebuild so the next tick's observations are judged against the
    /// new chain (silence timers keep running — a rebuild doesn't prove anything).
    public mutating func noteRebuilt() {
        deadCallbackSeconds = 0
    }
}
