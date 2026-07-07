import AppKit
import Foundation

// MARK: - ChatReader

/// Reads visible chat messages from the meeting app's chat panel via Accessibility
/// APIs. Requires Accessibility permission and — for Teams — the tree-wake nudge
/// in `MeetingDetector.enableMeetingAppAccessibility` to have already succeeded.
///
/// Opt-in only (`AppSettings.includeMeetingChat`, default off): unlike the roster
/// (names only) or in-meeting notes (the user's own words), this passively
/// captures other participants' written words without their per-message consent.
///
/// Mirrors `RosterReader`'s identifier-heuristic approach, but ships with only
/// Strategy 1 (known-identifier search): real AX identifiers for Teams' chat pane
/// are unknown, and unlike the roster panel (a flat list of short names, low risk
/// of a false-positive container match), guessing a generic "any list container"
/// fallback risks silently scraping the wrong panel (e.g. the roster) as if it
/// were chat. Once a live diagnostic dump (`diagnosticChatTreeDump`) shows Teams'
/// real chat structure, `chatIdentifiers` and `parseMessageRow` should be retuned
/// against it — same workflow already used to build `RosterReader`.
///
/// Known limitations (see handoff.md before improving this):
/// - Electron uses virtualized/lazy-rendered lists — only on-screen messages
///   exist in the AX tree. Scrollback and messages sent while the chat panel is
///   closed are unreachable; there is no way to recover them retroactively.
/// - Dedup is by exact (sender, text) match, owned by
///   `RecordingManager.updateChatMessages` — a legitimate repeated identical
///   short message ("yes", "+1") from the same sender is only captured once.
/// - Message edits/deletes are not reflected — Heard's copy reflects whatever
///   text was on screen the moment it was polled.
public enum ChatReader {

    /// Identifier/description keywords for the chat message list container.
    /// Unverified against real Teams output — see the type doc above.
    private static let chatIdentifiers = [
        "chat-pane-list", "chat-pane-message-list", "chat-list", "messages-list",
        "message-list", "chat-messages",
    ]

    /// UI strings to drop when a row's raw text is itself a control, not a message
    /// (e.g. a "Send" button living inside the same container).
    private static let controlStrings: Set<String> = [
        "send", "more options", "reply", "react", "like", "delete", "edit",
        "copy", "translate", "mark as unread", "add reaction", "attachment",
    ]

    /// Attempt to read the currently visible chat messages. Returns an empty
    /// array if Accessibility isn't granted, the chat panel isn't open, or no
    /// chat container matching a known identifier is found.
    public static func readChatMessages(pid: pid_t?) -> [(sender: String, text: String)] {
        guard let pid else { return [] }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        let app = AXUIElementNode(element)
        return readChatMessagesFromNode(app)
    }

    /// Testable entry point — accepts any AX tree node, including mocks.
    public static func readChatMessagesFromNode(_ app: any AXNode) -> [(sender: String, text: String)] {
        guard let windows = app.axChildren else { return [] }
        for window in windows {
            if let messages = searchForChatContainer(in: window, depth: 0, maxDepth: 10), !messages.isEmpty {
                return messages
            }
        }
        return []
    }

    private static func searchForChatContainer(
        in element: any AXNode, depth: Int, maxDepth: Int
    ) -> [(sender: String, text: String)]? {
        guard depth < maxDepth else { return nil }
        let combined = ((element.axIdentifier ?? "") + " " + (element.axDescription ?? "")).lowercased()
        if chatIdentifiers.contains(where: { combined.contains($0) }) {
            let messages = extractMessages(from: element)
            if !messages.isEmpty { return messages }
        }
        guard let children = element.axChildren else { return nil }
        for child in children {
            if let result = searchForChatContainer(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return result
            }
        }
        return nil
    }

    /// Extract (sender, text) pairs from a chat container's row children.
    private static func extractMessages(from container: any AXNode) -> [(sender: String, text: String)] {
        guard let rows = container.axChildren else { return [] }
        return rows.compactMap(parseMessageRow)
    }

    /// Best-effort per-row parse. Two shapes are tried, matching how
    /// `RosterReader.extractTextChildren` handles Teams' row-container pattern:
    /// (1) the row has sub-children — treat the first as sender, the rest joined
    /// as body; (2) the row is a single node whose own value/description/title
    /// encodes "Sender: text" or "Sender, text" for screen readers.
    private static func parseMessageRow(_ row: any AXNode) -> (sender: String, text: String)? {
        if let children = row.axChildren, children.count >= 2 {
            guard let sender = (children[0].axValue ?? children[0].axTitle)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty
            else { return nil }
            let body = children.dropFirst()
                .compactMap { $0.axValue ?? $0.axTitle }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return validated(sender: sender, text: body)
        }

        guard let raw = (row.axDescription ?? row.axValue ?? row.axTitle)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        for separator in [": ", ", "] {
            if let range = raw.range(of: separator) {
                let sender = String(raw[raw.startIndex..<range.lowerBound])
                let text = String(raw[range.upperBound...])
                if let result = validated(sender: sender, text: text) { return result }
            }
        }
        return nil
    }

    private static func validated(sender: String, text: String) -> (sender: String, text: String)? {
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !text.isEmpty else { return nil }
        guard sender.count <= 60, text.count <= 4000 else { return nil }
        guard !controlStrings.contains(text.lowercased()) else { return nil }
        // A sender exactly matching a control string means the row's structure
        // didn't put an actual name first (e.g. a stray button picked up as the
        // "sender" child) — unlike `text`, a real participant name is always
        // short, so exact-match here is safe and doesn't risk dropping genuine
        // messages the way substring-matching `text` would.
        guard !controlStrings.contains(sender.lowercased()) else { return nil }
        return (sender, text)
    }

    // MARK: - Diagnostics

    /// Developer-Mode diagnostic, parallel to `RosterReader.diagnosticTreeDump`.
    /// Dumps a bounded view of the app's AX tree so the chat parser's
    /// identifiers/heuristics can be built against Teams' actual structure once a
    /// real meeting has the chat panel open. Reuses `RosterReader`'s dump core —
    /// the chat container (if open) shows up in the same bounded tree walk.
    public static func diagnosticTreeDump(pid teamsPID: pid_t?) -> String? {
        RosterReader.diagnosticTreeDump(pid: teamsPID)
    }
}
