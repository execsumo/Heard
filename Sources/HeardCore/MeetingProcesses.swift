import AppKit
import CoreAudio
import Darwin
import Foundation

/// One process CoreAudio knows about (an entry in `kAudioHardwarePropertyProcessObjectList`),
/// plus the app that macOS holds responsible for it.
public struct AudioProcessInfo: Equatable, Sendable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    public var bundleID: String?
    /// The process macOS attributes this one to (`responsibility_get_pid_responsible_for_pid`).
    /// For an XPC service or helper — e.g. the `com.apple.WebKit.GPU` process that
    /// plays a web view's audio — this is the host app.
    public var responsiblePID: pid_t?
    public var responsibleBundleID: String?

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?,
                responsiblePID: pid_t? = nil, responsibleBundleID: String? = nil) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.responsiblePID = responsiblePID
        self.responsibleBundleID = responsibleBundleID
    }
}

/// Finds the processes that belong to a meeting app, for the audio tap and for
/// Accessibility reads.
///
/// Why: the meeting app's call audio isn't necessarily rendered by a process that
/// carries its bundle ID or shows up in `NSWorkspace.runningApplications`. Web-view
/// based clients play audio from an out-of-process XPC service (WebKit's GPU
/// process, `com.apple.WebKit.GPU`) or a helper that LaunchServices doesn't list,
/// and OS / client updates move audio between these. Tapping only the processes
/// that carry the app's bundle ID then yields a silent track — and because none
/// of those processes report output running, the health monitor never warns.
/// CoreAudio's own process list plus process responsibility catches all of them.
public enum MeetingProcesses {

    /// Pure selection: every audio process that is part of `source`'s family —
    /// by its own bundle ID, by PID (`familyPIDs` = the family as seen by
    /// NSWorkspace, plus the detected meeting PID), or by the app responsible for it.
    public static func select(
        _ processes: [AudioProcessInfo],
        for source: MeetingApp,
        familyPIDs: Set<pid_t>
    ) -> [AudioProcessInfo] {
        processes.filter { p in
            if familyPIDs.contains(p.pid) { return true }
            if source.isProcessFamilyMember(bundleID: p.bundleID, localizedName: nil) { return true }
            if let r = p.responsiblePID, familyPIDs.contains(r) { return true }
            if source.isProcessFamilyMember(bundleID: p.responsibleBundleID, localizedName: nil) { return true }
            return false
        }
    }

    /// All processes CoreAudio currently tracks, with their responsible app.
    /// Empty if the HAL can't answer (callers fall back to translate-PID).
    public static func allAudioProcesses() -> [AudioProcessInfo] {
        var listProp = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &listProp, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listProp, 0, nil, &size, &ids) == noErr else {
            return []
        }
        ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))

        let ownPID = getpid()
        return ids.compactMap { objectID in
            guard let pid = processPID(objectID), pid > 0, pid != ownPID else { return nil }
            let responsible = responsiblePID(for: pid)
            let responsibleOther = (responsible != nil && responsible != pid) ? responsible : nil
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: processBundleID(objectID),
                responsiblePID: responsibleOther,
                responsibleBundleID: responsibleOther.flatMap {
                    NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
                }
            )
        }
    }

    /// The PID whose windows should be read for the meeting title and roster.
    /// Detection reports whichever process holds the power assertion — which can
    /// be a helper with no windows. Prefer the detected PID when it is the main
    /// app, else the app responsible for it, else any running main app of `source`.
    public static func mainAppPID(for detectedPID: pid_t, source: MeetingApp) -> pid_t {
        func isMain(_ pid: pid_t) -> Bool {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return MeetingDetector.meetingAppFor(bundleID: app.bundleIdentifier, localizedName: app.localizedName) == source
        }
        if isMain(detectedPID) { return detectedPID }
        if let r = responsiblePID(for: detectedPID), r != detectedPID, isMain(r) { return r }
        let main = NSWorkspace.shared.runningApplications.first {
            MeetingDetector.meetingAppFor(bundleID: $0.bundleIdentifier, localizedName: $0.localizedName) == source
                && $0.activationPolicy == .regular
        }
        return main?.processIdentifier ?? detectedPID
    }

    // MARK: - HAL / libsystem lookups

    private static func processPID(_ objectID: AudioObjectID) -> pid_t? {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &prop, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func processBundleID(_ objectID: AudioObjectID) -> String? {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(objectID, &prop, 0, nil, &size, ptr)
        }
        guard err == noErr else { return nil }
        let id = ref as String
        return id.isEmpty ? nil : id
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` is exported by libsystem but
    /// not in the public headers; resolved at runtime so a missing symbol only
    /// loses the responsibility match.
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    public static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }
}
