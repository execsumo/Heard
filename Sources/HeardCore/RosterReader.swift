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

final class AXReadBudget {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var remaining = 5_000
    var available: Bool { remaining > 0 && ProcessInfo.processInfo.systemUptime < deadline }
}

final class AXUIElementNode: AXNode {
    private let element: AXUIElement
    private let budget: AXReadBudget
    init(_ element: AXUIElement, budget: AXReadBudget = AXReadBudget()) {
        self.element = element
        self.budget = budget
        budget.remaining -= 1
    }

    private func string(_ key: CFString) -> String? {
        guard budget.available else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, key, &ref) == .success else { return nil }
        return ref as? String
    }

    lazy var axRole: String? = string(kAXRoleAttribute as CFString)
    lazy var axIdentifier: String? = string(kAXIdentifierAttribute as CFString)
    lazy var axDescription: String? = string(kAXDescriptionAttribute as CFString)
    lazy var axValue: String? = string(kAXValueAttribute as CFString)
    lazy var axTitle: String? = string(kAXTitleAttribute as CFString)

    lazy var axChildren: [any AXNode]? = {
        guard budget.available else { return nil }
        var ref: AnyObject?
        // Native app roots can expose AXWindows without AXChildren (WebView hosts included).
        var elements: [AXUIElement] = []
        for key in [kAXWindowsAttribute, kAXChildrenAttribute] {
            guard budget.available else { break }
            ref = nil
            if AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success,
               let nodes = ref as? [AXUIElement] {
                for node in nodes {
                    guard budget.available, elements.count < budget.remaining else { break }
                    if !elements.contains(where: { CFEqual($0, node) }) { elements.append(node) }
                }
            }
        }
        // Application menu bars contain unrelated recent documents, not meeting metadata.
        return elements.compactMap { node -> (any AXNode)? in
            guard budget.available else { return nil }
            let child = AXUIElementNode(node, budget: budget)
            return child.axRole == "AXMenuBar" ? nil : child
        }
    }()
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
        // No AXIsProcessTrusted() pre-check: it returns a stale cached false on macOS 15+.
        let budget = AXReadBudget()
        for pid in metadataPIDs(preferred: teamsPID) {
            guard budget.available else { break }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.1)
            let app = AXUIElementNode(element, budget: budget)
            let names = readRosterFromNode(app)
            if !names.isEmpty { return names }
        }
        return parseWindowTitle()
    }

    /// Testable entry point — accepts any AX tree node, including mocks.
    /// Prefers the current Teams Attendees outline, then legacy identifiers/list containers.
    /// Does NOT include Strategy 3 (window title parsing), which requires live NSWorkspace.
    public static func readRosterFromNode(_ app: any AXNode) -> [String] {
        // Modern Teams has no roster identifiers; its row titles include status text.
        // Prefer the actual name leaves in the Participants > Attendees outline.
        if let names = findAttendees(in: app) { return names }
        if let names = findRosterPanel(in: app) { return names }
        if let names = findParticipantList(in: app) { return names }
        return []
    }

    /// Metadata UI hosts are distinct from power-assertion/audio processes in new Teams.
    public static func isTeamsMetadataApp(bundleID: String?, localizedName: String?) -> Bool {
        if let bundleID, ["com.microsoft.teams", "com.microsoft.teams2",
                          "com.microsoft.teams2.helper", "com.microsoft.teams2.modulehost"].contains(bundleID) {
            return true
        }
        return bundleID == nil && ["Microsoft Teams", "Microsoft Teams (work or school)",
                                   "Microsoft Teams classic", "Microsoft Teams WebView"].contains(localizedName ?? "")
    }

    static func metadataPIDs(preferred: pid_t?) -> [pid_t] {
        var pids = preferred.map { [$0] } ?? []
        for app in NSWorkspace.shared.runningApplications where isTeamsMetadataApp(
            bundleID: app.bundleIdentifier, localizedName: app.localizedName
        ) {
            if !pids.contains(app.processIdentifier) { pids.append(app.processIdentifier) }
        }
        return pids
    }

    // MARK: - Current Teams: Participants region / Attendees outline

    private static func findAttendees(in node: any AXNode, inParticipants: Bool = false, depth: Int = 0) -> [String]? {
        guard depth < 40 else { return nil }
        let labels = [node.axTitle, node.axDescription].compactMap { $0?.lowercased() }
        let inPane = inParticipants || (node.axRole == "AXGroup" && labels.contains("participants"))
        if inPane, node.axRole == "AXOutline", labels.contains("attendees") {
            var names: [String] = []
            func nameLeaf(in element: any AXNode, depth: Int) -> String? {
                guard depth < 12, !["AXButton", "AXImage", "AXTextField"].contains(element.axRole ?? "") else { return nil }
                if element.axRole == "AXStaticText" {
                    for value in [element.axValue, element.axTitle].compactMap({ $0 }) {
                        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = text.lowercased()
                        // Section rows, avatars and status labels are not names.
                        guard !lower.hasPrefix("in this meeting"), !lower.hasPrefix("waiting in lobby"),
                              !["organizer", "presenter", "attendee", "guest", "external", "muted", "unmuted"].contains(lower),
                              !filterNames([text]).isEmpty else { continue }
                        return text.replacingOccurrences(of: #"\s+\(You\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                    }
                    return nil
                }
                for child in element.axChildren ?? [] {
                    if let name = nameLeaf(in: child, depth: depth + 1) { return name }
                }
                return nil
            }
            func rows(in element: any AXNode, depth: Int) {
                guard depth < 12 else { return }
                if element.axRole == "AXRow" {
                    if let name = nameLeaf(in: element, depth: 0) { names.append(name) }
                    return
                }
                for child in element.axChildren ?? [] { rows(in: child, depth: depth + 1) }
            }
            rows(in: node, depth: 0)
            // A visible but empty roster must not fall through to unrelated app lists.
            return filterNames(names)
        }
        for child in node.axChildren ?? [] {
            if let names = findAttendees(in: child, inParticipants: inPane, depth: depth + 1) { return names }
        }
        return nil
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
        let identifier = (element.axIdentifier ?? "") + " " + (element.axDescription ?? "")
        let rosterIdentifiers = ["roster-list", "people-pane", "roster", "participants-list", "participant-list"]
        let isRosterContainer = rosterIdentifiers.contains(where: { identifier.lowercased().contains($0) })

        if isRosterContainer, element.axRole != "AXButton" {
            if let names = extractTextChildren(from: element) {
                let filtered = filterNames(names)
                if !filtered.isEmpty { return filtered }
            }
        }

        return searchChildrenForRoster(in: element, depth: 0, maxDepth: 30)
    }

    private static func searchChildrenForRoster(in element: any AXNode, depth: Int, maxDepth: Int) -> [String]? {
        guard depth < maxDepth else { return nil }
        guard let children = element.axChildren else { return nil }

        for child in children {
            let identifier = child.axIdentifier ?? ""
            let desc = child.axDescription ?? ""
            let combined = (identifier + " " + desc).lowercased()

            let rosterIdentifiers = ["roster", "people-pane", "participant"]
            if child.axRole != "AXButton", rosterIdentifiers.contains(where: { combined.contains($0) }) {
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
            if let names = findListContainers(in: window, depth: 0, maxDepth: 30) {
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
            if let names = extractTextChildren(from: element) {
                let filtered = filterNames(names)
                if filtered.count >= 2 { return filtered }
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
        let teamsPIDs = metadataPIDs(preferred: nil)

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

    private static func extractTextChildren(from element: any AXNode, depth: Int = 0) -> [String]? {
        guard depth < 16, let children = element.axChildren else { return nil }
        var texts: [String] = []

        func firstName(in node: any AXNode, depth: Int) -> String? {
            guard depth < 16, node.axRole != "AXButton", node.axRole != "AXTextField" else { return nil }
            // Empty AXValue must not hide a populated AXTitle.
            for text in [node.axValue, node.axTitle].compactMap({ $0 }) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !filterNames([trimmed]).isEmpty { return trimmed }
            }
            for child in node.axChildren ?? [] {
                if let name = firstName(in: child, depth: depth + 1) { return name }
            }
            return nil
        }
        func nestedListNames(in node: any AXNode, searchDepth: Int) -> [String]? {
            guard searchDepth < 16, depth + searchDepth < 16,
                  !["AXRow", "AXButton", "AXTextField"].contains(node.axRole ?? "") else { return nil }
            if ["AXList", "AXTable", "AXOutline"].contains(node.axRole ?? "") {
                return extractTextChildren(from: node, depth: depth + searchDepth + 1)
            }
            var names: [String] = []
            for child in node.axChildren ?? [] {
                names.append(contentsOf: nestedListNames(in: child, searchDepth: searchDepth + 1) ?? [])
            }
            return names.isEmpty ? nil : names
        }
        for child in children {
            // People panes often wrap their list in several unlabeled AXGroups.
            if let nested = nestedListNames(in: child, searchDepth: 0) {
                texts.append(contentsOf: nested)
            } else if let name = firstName(in: child, depth: 0) {
                texts.append(name)
            }
        }

        return texts.isEmpty ? nil : texts
    }

    /// Filter out UI control strings, too-short entries, and duplicates.
    static func filterNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            let lower = name.lowercased()
            guard !controlStrings.contains(lower) else { return false }
            guard name.count >= 2 && name.count <= 60 else { return false }
            guard !lower.hasPrefix("button") && !lower.hasPrefix("icon") else { return false }
            return seen.insert(lower).inserted
        }
    }

    // MARK: - Diagnostics

    /// Developer-Mode diagnostic. When `readRoster` comes back empty against a real
    /// (woken) Teams tree, this dumps a bounded view of the app's AX tree — roles,
    /// identifiers, descriptions, and truncated text — so the parser's hardcoded
    /// identifiers/heuristics can be retuned against Teams' actual structure. The
    /// roster parser has never been validated against live Teams output, so this is
    /// the data we need to close that gap. Live entry point: builds the app element
    /// and walks it on the caller's (background) thread.
    public static func diagnosticTreeDump(pid teamsPID: pid_t?) -> String? {
        guard let pid = teamsPID else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        return diagnosticTreeDump(root: AXUIElementNode(element))
    }

    /// Testable core: render any AX node tree as a compact, bounded textual outline.
    /// Depth-first (mirrors the parser's own traversal) with a shared node budget so
    /// a huge Electron tree can't produce an unbounded log. Text is truncated so the
    /// dump stays structural (metadata) rather than a verbatim content capture.
    public static func diagnosticTreeDump(root: any AXNode, maxDepth: Int = 9, nodeBudget: Int = 500) -> String? {
        var lines: [String] = []
        var remaining = nodeBudget

        func truncate(_ s: String, _ limit: Int = 40) -> String {
            let flat = s.replacingOccurrences(of: "\n", with: "⏎")
            return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…(\(flat.count))"
        }

        func walk(_ node: any AXNode, depth: Int) {
            guard remaining > 0 else { return }
            remaining -= 1
            var parts = ["\(String(repeating: "  ", count: depth))\(node.axRole ?? "?")"]
            if let id = node.axIdentifier, !id.isEmpty { parts.append("id=\(id)") }
            if let d = node.axDescription, !d.isEmpty { parts.append("desc=\(truncate(d))") }
            if let t = node.axTitle, !t.isEmpty { parts.append("title=\(truncate(t))") }
            if let v = node.axValue, !v.isEmpty { parts.append("value=\(truncate(v))") }
            lines.append(parts.joined(separator: " "))
            guard depth < maxDepth, let children = node.axChildren else { return }
            for child in children {
                if remaining <= 0 { break }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        if remaining <= 0 {
            lines.append("…(node budget \(nodeBudget) reached — tree truncated; raise the cap to see more)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
