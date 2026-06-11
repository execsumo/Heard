import AppKit
import Foundation

// MARK: - AX Tree Abstraction

/// Minimal abstraction over an accessibility tree node.
/// `AXUIElement` is adapted via `AXUIElementNode`; tests use `MockAXNode` loaded from JSON.
public protocol AXNode {
    var axRole: String? { get }
    var axIdentifier: String? { get }
    var axDescription: String? { get }
    var axValue: String? { get }
    var axTitle: String? { get }
    var axChildren: [any AXNode]? { get }
}

// MARK: - Live AX adapter

private struct AXUIElementNode: AXNode {
    private let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }

    private func string(_ key: CFString) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, key, &ref) == .success else { return nil }
        return ref as? String
    }

    var axRole: String?        { string(kAXRoleAttribute as CFString) }
    var axIdentifier: String?  { string(kAXIdentifierAttribute as CFString) }
    var axDescription: String? { string(kAXDescriptionAttribute as CFString) }
    var axValue: String?       { string(kAXValueAttribute as CFString) }
    var axTitle: String?       { string(kAXTitleAttribute as CFString) }

    var axChildren: [any AXNode]? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let elements = ref as? [AXUIElement] else { return nil }
        return elements.map { AXUIElementNode($0) as any AXNode }
    }
}

// MARK: - RosterReader

/// Reads participant names from the Microsoft Teams roster panel via Accessibility APIs.
/// Requires Accessibility permission (System Settings → Privacy → Accessibility).
public enum RosterReader {

    /// UI strings to filter out when reading roster entries.
    private static let controlStrings: Set<String> = [
        "mute", "unmute", "raise hand", "lower hand", "more actions",
        "pin", "unpin", "remove participant", "make presenter",
        "make attendee", "spotlight", "people", "participants",
        "in this meeting", "waiting in lobby", "search",
    ]

    /// Attempt to read participant names from the Teams roster.
    /// Returns an empty array if Accessibility isn't granted or the roster isn't visible.
    public static func readRoster(pid teamsPID: pid_t?) -> [String] {
        // Skip the AXIsProcessTrusted() pre-check: it returns a stale cached false on
        // macOS 15+ even when access is granted. AX API calls return .apiDisabled on
        // their own when genuinely denied, so the result is the same either way.
        guard let pid = teamsPID else { return parseWindowTitle() }

        let element = AXUIElementCreateApplication(pid)
        // Bound each AX round-trip so a busy/hung Teams can't stall the caller
        // for the system default timeout on every node of the tree walk.
        AXUIElementSetMessagingTimeout(element, 1.0)
        let app = AXUIElementNode(element)
        let names = readRosterFromNode(app)
        return names.isEmpty ? parseWindowTitle() : names
    }

    /// Testable entry point — accepts any AX tree node, including mocks.
    /// Runs Strategy 1 (known identifiers) then Strategy 2 (AXList containers).
    /// Does NOT include Strategy 3 (window title parsing), which requires live NSWorkspace.
    public static func readRosterFromNode(_ app: any AXNode) -> [String] {
        if let names = findRosterPanel(in: app) { return names }
        if let names = findParticipantList(in: app) { return names }
        return []
    }

    // MARK: - Strategy 1: Known Roster Panel Identifiers

    private static func findRosterPanel(in app: any AXNode) -> [String]? {
        guard let windows = app.axChildren else { return nil }

        for window in windows {
            if let names = searchForRosterByIdentifier(in: window) {
                let filtered = filterNames(names)
                if !filtered.isEmpty { return filtered }
            }
        }
        return nil
    }

    private static func searchForRosterByIdentifier(in element: any AXNode) -> [String]? {
        let identifier = element.axIdentifier ?? element.axDescription ?? ""
        let rosterIdentifiers = ["roster-list", "people-pane", "roster", "participants-list", "participant-list"]
        let isRosterContainer = rosterIdentifiers.contains(where: { identifier.lowercased().contains($0) })

        if isRosterContainer {
            return extractTextChildren(from: element)
        }

        return searchChildrenForRoster(in: element, depth: 0, maxDepth: 8)
    }

    private static func searchChildrenForRoster(in element: any AXNode, depth: Int, maxDepth: Int) -> [String]? {
        guard depth < maxDepth else { return nil }
        guard let children = element.axChildren else { return nil }

        for child in children {
            let identifier = child.axIdentifier ?? ""
            let desc = child.axDescription ?? ""
            let combined = (identifier + " " + desc).lowercased()

            let rosterIdentifiers = ["roster", "people-pane", "participant"]
            if rosterIdentifiers.contains(where: { combined.contains($0) }) {
                if let names = extractTextChildren(from: child) {
                    let filtered = filterNames(names)
                    if !filtered.isEmpty { return filtered }
                }
            }

            if let result = searchChildrenForRoster(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return result
            }
        }
        return nil
    }

    // MARK: - Strategy 2: Find AXList/AXTable with Multiple Text Rows

    private static func findParticipantList(in app: any AXNode) -> [String]? {
        guard let windows = app.axChildren else { return nil }

        for window in windows {
            if let names = findListContainers(in: window, depth: 0, maxDepth: 10) {
                let filtered = filterNames(names)
                if filtered.count >= 2 { return filtered }
            }
        }
        return nil
    }

    private static func findListContainers(in element: any AXNode, depth: Int, maxDepth: Int) -> [String]? {
        guard depth < maxDepth else { return nil }

        let role = element.axRole ?? ""
        if role == "AXList" || role == "AXTable" || role == "AXOutline" {
            if let names = extractTextChildren(from: element), names.count >= 2 {
                return names
            }
        }

        guard let children = element.axChildren else { return nil }
        for child in children {
            if let result = findListContainers(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return result
            }
        }
        return nil
    }

    // MARK: - Strategy 3: Parse Window Title (via Accessibility API)

    /// Pure parser: given a Teams window title like "Alice, Bob | Microsoft Teams",
    /// return the participant names. Returns [] if the title doesn't match the
    /// expected pattern or has fewer than 2 names.
    public static func parseParticipantsFromWindowTitle(_ title: String) -> [String] {
        guard title.contains(" | Microsoft Teams") else { return [] }
        let prefix = title.replacingOccurrences(
            of: #"\s*\|\s*Microsoft Teams.*$"#,
            with: "",
            options: .regularExpression
        )
        guard prefix.contains(",") else { return [] }

        let names = prefix.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 2 }

        return names.count >= 2 ? names : []
    }

    /// Pure filter: drop UI control strings, too-short/too-long entries, and duplicates.
    /// Exposed for testing — roster extraction strategies feed their raw results through this.
    public static func filterNamesForTesting(_ names: [String]) -> [String] {
        filterNames(names)
    }

    private static func parseWindowTitle() -> [String] {
        let teamsNames: Set<String> = [
            "Microsoft Teams",
            "Microsoft Teams (work or school)",
            "Microsoft Teams classic",
        ]

        let teamsPIDs = NSWorkspace.shared.runningApplications
            .filter { app in
                guard let name = app.localizedName else { return false }
                return teamsNames.contains(name)
            }
            .map { $0.processIdentifier }

        for pid in teamsPIDs {
            let app = AXUIElementCreateApplication(pid)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement]
            else { continue }

            for window in windows {
                var titleRef: AnyObject?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String
                else { continue }
                let names = parseParticipantsFromWindowTitle(title)
                if !names.isEmpty { return names }
            }
        }
        return []
    }

    // MARK: - Shared helpers

    private static func extractTextChildren(from element: any AXNode) -> [String]? {
        guard let children = element.axChildren else { return nil }
        var texts: [String] = []

        for child in children {
            // Try direct value/title
            if let text = child.axValue ?? child.axTitle {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
                continue
            }

            // Try first text child (for row containers)
            if let subChildren = child.axChildren {
                for sub in subChildren {
                    if let text = sub.axValue ?? sub.axTitle {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            texts.append(trimmed)
                            break
                        }
                    }
                }
            }
        }

        return texts.isEmpty ? nil : texts
    }

    /// Filter out UI control strings, too-short entries, and duplicates.
    private static func filterNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            let lower = name.lowercased()
            guard !controlStrings.contains(lower) else { return false }
            guard name.count >= 2 && name.count <= 60 else { return false }
            guard !lower.hasPrefix("button") && !lower.hasPrefix("icon") else { return false }
            return seen.insert(lower).inserted
        }
    }
}
