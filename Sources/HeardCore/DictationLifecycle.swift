import Foundation

/// What a dictation hotkey or menu press does, given the session's intent flags.
/// Pure, so the AppModel decision is tested without audio or UI.
public enum DictationToggleAction: Equatable {
    case start
    case stop
    /// Press during a pending start is a stop request: cancel the start, release the mic, publish nothing.
    case cancelPendingStart
    case ignore
}

public func dictationToggleAction(
    isDictating: Bool,
    startPending: Bool,
    stopInFlight: Bool,
    managerTranscribing: Bool,
    meetingActive: Bool
) -> DictationToggleAction {
    if startPending { return .cancelPendingStart }
    // A stop still transcribing is never interrupted by a press, whichever path started it.
    if stopInFlight || managerTranscribing { return .ignore }
    if isDictating { return .stop }
    if meetingActive { return .ignore }
    return .start
}

/// Whether a start that just returned may publish "listening" to the UI.
/// Otherwise the caller must stop the session it just started.
public func dictationMayPublishListening(
    managerState: DictationState,
    meetingActive: Bool,
    pushToTalkReleased: Bool,
    superseded: Bool
) -> Bool {
    managerState == .listening && !meetingActive && !pushToTalkReleased && !superseded
}
