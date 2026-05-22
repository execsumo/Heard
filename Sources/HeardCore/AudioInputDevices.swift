import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// A microphone-capable CoreAudio device the user can select for dictation and
/// meeting recording.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio device UID — stable across launches and unplug/replug.
    public let uid: String
    /// Transient CoreAudio device ID, only valid for the current process lifetime.
    public let deviceID: AudioDeviceID
    public let name: String

    public var id: String { uid }
}

/// Enumerates input devices via CoreAudio and applies a user-chosen device to
/// an `AVAudioEngine`. UID is persisted in settings; the transient device ID
/// is resolved at engine-start time, so devices that have been unplugged or
/// renumbered between launches are handled gracefully.
public enum AudioInputDevices {

    /// All connected audio devices that expose at least one input stream.
    public static func list() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
            ) == noErr,
            size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
            ) == noErr
        else { return [] }

        return ids.compactMap { deviceID -> AudioInputDevice? in
            guard hasInputStreams(deviceID) else { return nil }
            guard
                let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
                    ?? stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return AudioInputDevice(uid: uid, deviceID: deviceID, name: name)
        }
    }

    /// Resolve a saved UID to the current `AudioDeviceID`, or nil if the
    /// device isn't connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        list().first { $0.uid == uid }?.deviceID
    }

    /// The current system default input device, if any.
    public static func defaultInputDevice() -> AudioInputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
            ) == noErr,
            deviceID != 0,
            let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
            let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
                ?? stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
        else { return nil }
        return AudioInputDevice(uid: uid, deviceID: deviceID, name: name)
    }

    /// Set the chosen device on the engine's input audio unit. Must be called
    /// BEFORE `inputNode.outputFormat(forBus:)` or any tap install, since
    /// changing the device changes the format. A nil UID, an unknown UID, or
    /// an unplugged device leaves the system default in place.
    @discardableResult
    public static func apply(uid: String?, to engine: AVAudioEngine) -> Bool {
        guard let uid, !uid.isEmpty, let deviceID = deviceID(forUID: uid) else {
            return false
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            NSLog("Heard: AudioInputDevices.apply — input node has no audio unit")
            return false
        }
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        if status != noErr {
            NSLog("Heard: AudioInputDevices.apply failed (uid=%@): %d", uid, status)
            return false
        }
        return true
    }

    // MARK: - Private

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &addr, 0, nil, &size, &cfString
        )
        guard status == noErr, let value = cfString else { return nil }
        return value.takeRetainedValue() as String
    }
}
