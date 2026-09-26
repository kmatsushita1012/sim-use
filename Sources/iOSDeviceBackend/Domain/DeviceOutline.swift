// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Renders a device element tree as an indented outline.
///
/// There are no frames on this channel, so the outline cannot sort or group by
/// screen position the way the simulator one does. Nesting and traversal order
/// carry that structure instead — which is the accessibility reading order, and
/// is arguably a better ordering to hand an agent than y-coordinates.
public struct DeviceOutline {
    /// Codable so `ui --json` can carry the outline structurally; the
    /// synthesized coding omits `identifier` when absent, matching the
    /// rendered form (no trailing `#`).
    public struct Row: Codable, Equatable, Sendable {
        public let depth: Int
        public let role: String
        public let label: String
        public let identifier: String?
    }

    public let rows: [Row]

    public init(elements: [DeviceElement]) {
        var rows: [Row] = []
        var depths: [Int: Int] = [:]

        for (index, element) in elements.enumerated() {
            let parentDepth = element.parent.flatMap { depths[$0] } ?? -1
            guard element.isAccessibilityElement else {
                depths[index] = parentDepth
                continue
            }
            let depth = parentDepth + 1
            depths[index] = depth
            // Render the identifier trimmed so the shown `#id` is exactly what
            // `tap #<id>` matches — no leading/trailing whitespace to copy by
            // mistake. A whitespace-only identifier renders as none.
            let identifier = element.identifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(Row(
                depth: depth,
                role: element.role,
                label: Self.label(from: element.summary, role: element.role),
                identifier: identifier?.isEmpty == false ? identifier : nil
            ))
        }
        self.rows = rows
    }

    public func rendered() -> String {
        Self.rendered(rows: rows)
    }

    /// Static so a decoded `ExecutionResult` can be re-rendered without
    /// rebuilding the element tree.
    public static func rendered(rows: [Row]) -> String {
        rows.map { row in
            let indent = String(repeating: "  ", count: min(row.depth, 8))
            let label = row.label.isEmpty ? "" : "\"\(row.label)\""
            let id = row.identifier.map { "  #\($0)" } ?? ""
            return "\(indent)\(row.role)  \(label)\(id)"
        }.joined(separator: "\n")
    }

    /// The daemon's description already ends with the role ("Chats Button,
    /// Selected"), and repeating it in the rendered row is noise.
    static func label(from summary: String, role: String) -> String {
        guard !role.isEmpty else { return summary }
        let trimmed = summary.hasSuffix(role)
            ? String(summary.dropLast(role.count))
            : summary
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }
}
