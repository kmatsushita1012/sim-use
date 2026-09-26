// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct DeviceElement: Sendable {
    public let element: AXAuditElement
    public let summary: String
    public let role: String
    public let identifier: String?
    public let depth: Int
    public let parent: Int?
    public let isIgnored: Bool

    public init(
        element: AXAuditElement,
        summary: String,
        role: String,
        identifier: String? = nil,
        depth: Int,
        parent: Int?,
        isIgnored: Bool
    ) {
        self.element = element
        self.summary = summary
        self.role = role
        self.identifier = identifier
        self.depth = depth
        self.parent = parent
        self.isIgnored = isIgnored
    }

    public var isAccessibilityElement: Bool { !role.isEmpty && !isIgnored }
}

/// Walks the on-device element tree breadth-first.
///
/// Enumeration goes through `_AXHierarchyElementsAttribute` rather than
/// inspector focus movement on purpose: focus movement is VoiceOver-style and
/// scrolls offscreen elements into view, so a focus-based `ui` would leave the
/// screen scrolled to the bottom — and there is no safe undo, because
/// re-focusing a stale token lands on a recycled cell and reads as a selection.
/// The hierarchy walk is inert; measured drift across repeated full walks stays
/// under 1% of pixels, all of it app animation.
public struct DeviceTreeFetcher: Sendable {
    /// Measured on a chat list: 16 halves the wall clock against serial, 32
    /// adds nothing — the daemon serialises beyond that.
    public static let defaultConcurrency = 16
    public static let defaultNodeLimit = 1500

    private let client: AXAuditClient
    private let concurrency: Int
    private let nodeLimit: Int
    private let stopsAtLabelledNodes: Bool

    public init(
        client: AXAuditClient,
        concurrency: Int = defaultConcurrency,
        nodeLimit: Int = defaultNodeLimit,
        stopsAtLabelledNodes: Bool = false
    ) {
        self.client = client
        self.concurrency = concurrency
        self.nodeLimit = nodeLimit
        self.stopsAtLabelledNodes = stopsAtLabelledNodes
    }

    public func fetchTree() async throws -> [DeviceElement] {
        let root = try await client.rootElement()
        var discovered: [DeviceElement] = []
        // Dedup on (token, summary, role), not the bare token. On a pushed
        // screen `deviceFetchSpecialElement: 0` returns the navigation-bar back
        // button as the root — its token then aliases a real element, so seeding
        // `visited` with the root token silently dropped the back button (it read
        // as "root, already seen"). The composite key keeps the back button while
        // still collapsing the genuine repeats the deep child walk produces.
        var visited: Set<String> = []
        var frontier: [(element: AXAuditElement, index: Int?)] = [(root, nil)]
        var depth = 0

        while !frontier.isEmpty, discovered.count < nodeLimit {
            let expansions = try await expand(frontier.map(\.element))
            var next: [(element: AXAuditElement, index: Int?)] = []

            for (offset, children) in expansions.enumerated() {
                let parent = frontier[offset].index
                for child in children where visited.insert(child.identityKey).inserted {
                    discovered.append(DeviceElement(
                        element: child.element,
                        summary: child.summary,
                        role: child.role,
                        identifier: child.identifier,
                        depth: depth,
                        parent: parent,
                        isIgnored: child.isIgnored
                    ))
                    // Expanding every node — labelled ones included — is the
                    // default because a labelled node still has labelled
                    // descendants: stopping at them is around a third fewer
                    // round trips but loses a fifth of the real elements.
                    if !stopsAtLabelledNodes || child.role.isEmpty {
                        next.append((child.element, discovered.count - 1))
                    }
                }
            }

            frontier = next
            depth += 1
        }

        guard !discovered.isEmpty else { throw AXAuditError.hierarchyUnavailable }
        return discovered
    }

    private func expand(_ elements: [AXAuditElement]) async throws -> [[AXAuditNode]] {
        try await withThrowingTaskGroup(of: (Int, [AXAuditNode]).self) { group in
            var results = [[AXAuditNode]](repeating: [], count: elements.count)
            var next = 0

            func addTask(_ index: Int) {
                group.addTask {
                    (index, try await client.children(of: elements[index]))
                }
            }

            while next < min(concurrency, elements.count) {
                addTask(next)
                next += 1
            }
            while let (index, children) = try await group.next() {
                results[index] = children
                if next < elements.count {
                    addTask(next)
                    next += 1
                }
            }
            return results
        }
    }
}
