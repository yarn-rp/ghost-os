// RegionAX.swift - Extract the accessibility-tree subtree whose frame
// intersects a given screen rectangle.
//
// The hard part: getting USEFUL content out of Chromium-based apps (Claude
// for desktop, VS Code, Slack, Discord, Chrome itself). In those apps,
// AXorcist's typed `value()` accessor returns nil for `AXStaticText` —
// the actual text lives in the raw `AXValue` attribute. The flow42
// CLAUDE.md flags this as a known gotcha; we reach through `rawAttributeValue`
// to get the real content.
//
// We also aggressively filter scaffolding (empty AXGroup containers,
// duplicate elements visited via different parent chains, AXSplitter, etc.)
// so the agent gets a tight, signal-dense list instead of div soup.
//
// Coordinate space: rect must be in **AX coords** (origin = top-left of the
// PRIMARY display, Y increasing downward). The caller is responsible for
// the AppKit-bottom-left → AX-top-left conversion before calling.

import AppKit
import ApplicationServices
import AXorcist
import Foundation

public enum RegionAX {

    /// Walk the AX tree of the given app (or the frontmost app when pid=nil)
    /// and collect every meaningful element whose frame intersects `rect`.
    ///
    /// Each returned dict carries:
    ///   - role         AXRole, e.g. "AXButton"
    ///   - name         best-effort label (computedName / title / description)
    ///   - text         actual text content for static-text-style roles
    ///                  (read via raw AXValue, since typed accessors lie in
    ///                  Chromium apps)
    ///   - value        any non-text AXValue (slider position, checkbox bool)
    ///   - identifier   AXIdentifier when set
    ///   - x, y, w, h   element frame in AX coords
    ///   - depth        AX-tree depth from the app root
    public static func extract(
        rect: CGRect,
        pid: pid_t? = nil,
        maxResults: Int = 200,
        maxDepth: Int = 50
    ) -> [[String: Any]] {
        let appPid: pid_t
        if let pid {
            appPid = pid
        } else if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            appPid = front
        } else {
            return []
        }

        let appElement = Element(AXUIElementCreateApplication(appPid))
        var results: [[String: Any]] = []
        var visited: Set<Element> = []
        walk(
            element: appElement,
            depth: 0,
            rect: rect,
            results: &results,
            visited: &visited,
            maxResults: maxResults,
            maxDepth: maxDepth
        )
        return results
    }

    private static func walk(
        element: Element,
        depth: Int,
        rect: CGRect,
        results: inout [[String: Any]],
        visited: inout Set<Element>,
        maxResults: Int,
        maxDepth: Int
    ) {
        if results.count >= maxResults || depth > maxDepth { return }
        // Identity-dedup: same AXUIElement reachable via two parent chains
        // (happens in apps with focused-element shadow roots) shouldn't be
        // serialized twice.
        if !visited.insert(element).inserted { return }

        var elementOverlapsRect = false

        if let pos = element.position(),
           let size = element.size(),
           size.width > 0, size.height > 0 {
            let frame = CGRect(
                x: CGFloat(pos.x),
                y: CGFloat(pos.y),
                width: CGFloat(size.width),
                height: CGFloat(size.height)
            )
            if frame.intersects(rect) {
                elementOverlapsRect = true
                if let dict = serialize(element: element, frame: frame, depth: depth) {
                    results.append(dict)
                }
            } else {
                // Element is fully outside our rect — but its CHILDREN may
                // still be inside (in transformed contexts). Continue walking
                // anyway. Empirically: pruning here costs more than it saves
                // because Chromium apps wrap content in zero-or-tiny groups.
                _ = elementOverlapsRect
            }
        }

        guard let children = element.children() else { return }
        for child in children {
            walk(
                element: child,
                depth: depth + 1,
                rect: rect,
                results: &results,
                visited: &visited,
                maxResults: maxResults,
                maxDepth: maxDepth
            )
            if results.count >= maxResults { return }
        }
    }

    // MARK: - Serialize

    /// Convert an Element into a dict, OR return nil to skip it (when it's
    /// purely structural scaffolding with no signal).
    private static func serialize(
        element: Element,
        frame: CGRect,
        depth: Int
    ) -> [String: Any]? {
        let role = element.role() ?? ""

        // Roots that always intersect because they own the screen.
        if hardSkipRole(role) { return nil }

        // Pull the best label via the standard chain. computedName is usually
        // the most useful (it's what VoiceOver would say).
        var name = nonEmpty(element.computedName())
            ?? nonEmpty(element.title())
            ?? nonEmpty(element.descriptionText())

        // For text-bearing roles, the typed value() accessor returns nil in
        // Chromium-based apps. Read the raw AXValue attribute and pull a
        // string out of it — that's the ACTUAL text content.
        var text: String? = nil
        if textBearingRole(role) {
            text = readStringAttribute(element, attribute: kAXValueAttribute as String)
            // Frequently, computedName falls through to the role's plain
            // English ("StaticText", "Group"). When we have real text and
            // no real name, use the text as the name and don't duplicate.
            if let extracted = text,
               (name == nil || nameLooksLikeRolePlaceholder(name!, role: role)) {
                name = extracted
                text = nil
            }
        } else {
            // Non-text element — surface a non-string AXValue if present
            // (slider position, checkbox bool, progress fraction).
            if let v = element.value() {
                text = compactDescription(v)
            }
        }

        // Skip pure scaffolding: structural role + nothing useful inside.
        if structuralRole(role), name == nil, text == nil {
            return nil
        }

        // Skip elements where the only "name" is the role-placeholder noise.
        if let n = name, nameLooksLikeRolePlaceholder(n, role: role), text == nil {
            return nil
        }

        var dict: [String: Any] = [
            "role": role,
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "w": Double(frame.width),
            "h": Double(frame.height),
            "depth": depth,
        ]
        if let name {
            dict["name"] = name
        }
        if let text {
            dict["text"] = String(text.prefix(2000))
        }
        if let identifier = element.identifier(), !identifier.isEmpty {
            dict["identifier"] = identifier
        }
        // For links, surface the URL — agents will want it.
        if role == "AXLink",
           let urlString = readStringAttribute(element, attribute: kAXURLAttribute as String) {
            dict["url"] = urlString
        }
        return dict
    }

    // MARK: - Role classification

    /// Roles we never want in the output regardless of content. Whole-screen
    /// scaffolding that always intersects everything.
    private static func hardSkipRole(_ role: String) -> Bool {
        switch role {
        case "AXApplication", "AXWindow", "AXSplitter", "AXSplitGroup",
             "AXLayoutArea", "AXLayoutItem", "AXScrollBar":
            return true
        default:
            return false
        }
    }

    /// "Structural" = a container that's only useful when it has a meaningful
    /// name or value. AXGroup with no name is the classic React div-soup case.
    private static func structuralRole(_ role: String) -> Bool {
        switch role {
        case "AXGroup", "AXGenericElement", "AXScrollArea", "AXList",
             "AXOutline", "AXToolbar", "AXTabGroup", "AXUnknown":
            return true
        default:
            return false
        }
    }

    /// Roles whose "real" content lives in AXValue (often as a string).
    private static func textBearingRole(_ role: String) -> Bool {
        switch role {
        case "AXStaticText", "AXTextField", "AXTextArea", "AXLink",
             "AXListMarker", "AXHeading", "AXValueIndicator":
            return true
        default:
            return false
        }
    }

    /// computedName() / descriptionText() in some apps falls through to the
    /// role's plain-English alias ("StaticText", "Group", "List"). Treat
    /// these as no-name so they don't crowd out the real signal.
    private static func nameLooksLikeRolePlaceholder(_ name: String, role: String) -> Bool {
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return name == stripped
            || name == "Group"
            || name == "WebArea"
            || name == "GenericElement"
            || name == "Unknown"
    }

    // MARK: - AX raw helpers

    /// Read an AX attribute as a String via the raw API. This is the
    /// workaround for typed accessors returning nil in Chromium apps.
    private static func readStringAttribute(_ element: Element, attribute: String) -> String? {
        guard let raw = element.rawAttributeValue(named: attribute) else { return nil }
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        if let url = raw as? URL { return url.absoluteString }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    /// Compact, JSON-serializable summary of an AXValue when it's not a
    /// plain String. Mostly useful for slider / checkbox / progress values.
    private static func compactDescription(_ value: Any) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let b = value as? Bool { return b ? "true" : "false" }
        let s = String(describing: value)
        return s.isEmpty ? nil : s
    }
}
