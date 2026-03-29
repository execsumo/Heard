import AppKit
import Foundation

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
    public static func readRoster(teamsPID: pid_t?) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        guard let pid = teamsPID else { return parseWindowTitle() }

        let app = AXUIElementCreateApplication(pid)

        // Strategy 1: Find the roster panel by known identifiers
        if let names = findRosterPanel(in: app) {
            return names
        }

        // Strategy 2: Search for AXList/AXTable containers with participant-like content
        if let names = findParticipantList(in: app) {
            return names
        }

        // Strategy 3: Parse window title pattern "Name1, Name2 | Microsoft Teams"
        return parseWindowTitle()
    }

    // MARK: - Strategy 1: Known Roster Panel Identifiers

    private static func findRosterPanel(in app: AXUIElement) -> [String]? {
        // Look for windows, then search for known roster identifiers
        guard let windows = getChildren(of: app) else { return nil }

        for window in windows {
            if let names = searchForRosterByIdentifier(in: window) {
                let filtered = filterNames(names)
                if !filtered.isEmpty { return filtered }
            }
        }
        return nil
    }

    private static func searchForRosterByIdentifier(in element: AXUIElement) -> [String]? {
        // Check if this element has a roster-related identifier
        let identifier = getStringAttribute(element, attribute: kAXIdentifierAttribute as CFString)
            ?? getStringAttribute(element, attribute: kAXDescriptionAttribute as CFString)
            ?? ""

        let rosterIdentifiers = ["roster-list", "people-pane", "roster", "participants-list", "participant-list"]
        let isRosterContainer = rosterIdentifiers.contains(where: { identifier.lowercased().contains($0) })

        if isRosterContainer {
            return extractTextChildren(from: element)
        }

        // Recurse into children (limit depth to avoid excessive traversal)
        return searchChildrenForRoster(in: element, depth: 0, maxDepth: 8)
    }

    private static func searchChildrenForRoster(in element: AXUIElement, depth: Int, maxDepth: Int) -> [String]? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        for child in children {
            let identifier = getStringAttribute(child, attribute: kAXIdentifierAttribute as CFString) ?? ""
            let desc = getStringAttribute(child, attribute: kAXDescriptionAttribute as CFString) ?? ""
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

    private static func findParticipantList(in app: AXUIElement) -> [String]? {
        guard let windows = getChildren(of: app) else { return nil }

        for window in windows {
            if let names = findListContainers(in: window, depth: 0, maxDepth: 10) {
                let filtered = filterNames(names)
                if filtered.count >= 2 { return filtered }
            }
        }
        return nil
    }

    private static func findListContainers(in element: AXUIElement, depth: Int, maxDepth: Int) -> [String]? {
        guard depth < maxDepth else { return nil }

        let role = getStringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""

        // Look for list/table/outline containers
        if role == "AXList" || role == "AXTable" || role == "AXOutline" {
            if let names = extractTextChildren(from: element), names.count >= 2 {
                return names
            }
        }

        guard let children = getChildren(of: element) else { return nil }
        for child in children {
            if let result = findListContainers(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return result
            }
        }
        return nil
    }

    // MARK: - Strategy 3: Parse Window Title (via Accessibility API)

    private static func parseWindowTitle() -> [String] {
        guard AXIsProcessTrusted() else { return [] }

        let teamsNames: Set<String> = [
            "Microsoft Teams",
            "Microsoft Teams (work or school)",
            "Microsoft Teams classic",
        ]

        // Find Teams PIDs from running applications
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
                      let title = titleRef as? String,
                      title.contains(" | Microsoft Teams")
                else { continue }

                // Pattern: "Name1, Name2, Name3 | Microsoft Teams"
                let prefix = title.replacingOccurrences(of: #"\s*\|\s*Microsoft Teams.*$"#, with: "", options: .regularExpression)
                guard prefix.contains(",") else { continue }

                let names = prefix.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count >= 2 }

                if names.count >= 2 { return names }
            }
        }
        return []
    }

    // MARK: - AX Helpers

    private static func getChildren(of element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return nil }
        return children
    }

    private static func getStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func extractTextChildren(from element: AXUIElement) -> [String]? {
        guard let children = getChildren(of: element) else { return nil }
        var texts: [String] = []

        for child in children {
            // Try direct value/title
            if let text = getStringAttribute(child, attribute: kAXValueAttribute as CFString)
                ?? getStringAttribute(child, attribute: kAXTitleAttribute as CFString) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
                continue
            }

            // Try first text child (for row containers)
            if let subChildren = getChildren(of: child) {
                for sub in subChildren {
                    if let text = getStringAttribute(sub, attribute: kAXValueAttribute as CFString)
                        ?? getStringAttribute(sub, attribute: kAXTitleAttribute as CFString) {
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
            // Skip control strings
            guard !controlStrings.contains(lower) else { return false }
            // Skip very short or very long entries (likely not names)
            guard name.count >= 2 && name.count <= 60 else { return false }
            // Skip entries that look like UI elements
            guard !lower.hasPrefix("button") && !lower.hasPrefix("icon") else { return false }
            // Deduplicate
            return seen.insert(lower).inserted
        }
    }
}
