import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// End-to-end check of the System Audio (kTCCServiceAudioCapture) grant.
///
/// macOS has no API to query that grant, and on macOS 26 a denied grant doesn't
/// fail tap creation — the tap returns `noErr` and delivers all-zero samples. So
/// the only trustworthy check is to listen: play an inaudible tone (−80 dBFS)
/// from Heard itself, tap system output, and see whether the tone arrives.
/// Creating the tap is also what shows the macOS prompt the first time. ~1 s.
enum SystemAudioProbe {
    enum Outcome: Equatable {
        /// The tap heard the tone — the grant works.
        case verified
        /// The tap ran but delivered only zeros — the grant is denied or pending.
        case silent
        /// The probe couldn't run (no output device, HAL error).
        case unavailable
    }

    private final class Counters: @unchecked Sendable {
        var cycles = 0
        var nonZero = 0
    }

    private final class Phase: @unchecked Sendable {
        var value: Double = 0
    }

    @MainActor
    static func run() async -> Outcome {
        // ── Tone source: −80 dBFS keeps it inaudible but non-zero in the tap ──
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0,
              let toneFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else {
            NSLog("Heard: System Audio probe — no output device")
            return .unavailable
        }
        let phase = Phase()
        let step = 2 * Double.pi * 440 / sampleRate
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(phase.value)) * 0.0001
                phase.value += step
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: toneFormat)
        do {
            try engine.start()
        } catch {
            NSLog("Heard: System Audio probe — tone engine failed: %@", error.localizedDescription)
            return .unavailable
        }
        defer { engine.stop() }

        // ── Global tap (unmuted — the user's audio is untouched) ──────────────
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Heard Permission Probe"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID: AudioObjectID = 0
        let tapErr = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapErr == noErr else {
            NSLog("Heard: System Audio probe — tap creation failed (%d)", tapErr)
            return .unavailable
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        // ── Private aggregate on the default output device carrying the tap ───
        guard let outputUID = defaultOutputDeviceUID() else {
            NSLog("Heard: System Audio probe — no default output device UID")
            return .unavailable
        }
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Heard Probe",
            kAudioAggregateDeviceUIDKey as String: "\(AudioDeviceCleanup.heardAggregateUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapDriftCompensationKey as String: true,
                 kAudioSubTapUIDKey as String: desc.uuid.uuidString]
            ],
        ]
        var aggregateID: AudioObjectID = 0
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggErr == noErr else {
            NSLog("Heard: System Audio probe — aggregate creation failed (%d)", aggErr)
            return .unavailable
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        // ── Count non-zero samples for a moment ───────────────────────────────
        let counters = Counters()
        let queue = DispatchQueue(label: "com.execsumo.heard.audioprobe")
        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            counters.cycles += 1
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData)) {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let samples = data.bindMemory(to: Float32.self, capacity: count)
                for i in 0..<count where samples[i] != 0 {
                    counters.nonZero += 1
                    break
                }
            }
        }
        guard ioErr == noErr, let validProc = procID else {
            NSLog("Heard: System Audio probe — IOProc creation failed (%d)", ioErr)
            return .unavailable
        }
        defer { AudioDeviceDestroyIOProcID(aggregateID, validProc) }

        let startErr = AudioDeviceStart(aggregateID, validProc)
        guard startErr == noErr else {
            NSLog("Heard: System Audio probe — device start failed (%d)", startErr)
            return .unavailable
        }
        try? await Task.sleep(for: .milliseconds(800))
        AudioDeviceStop(aggregateID, validProc)
        // Drain blocks already queued before reading the counters.
        let (cycles, nonZero) = queue.sync { (counters.cycles, counters.nonZero) }

        let outcome: Outcome = nonZero > 0 ? .verified : (cycles > 0 ? .silent : .unavailable)
        NSLog("Heard: System Audio probe — %@ (cycles=%d, nonZeroBuffers=%d)",
              String(describing: outcome), cycles, nonZero)
        DebugFileLog.log("system audio probe: outcome=\(outcome) cycles=\(cycles) nonZeroBuffers=\(nonZero)")
        return outcome
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return RecordingManager.copyDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }
}
