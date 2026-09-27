// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import iOSDeviceBackend

@Suite("DeviceTreeFetcher dedup")
struct DeviceTreeFetcherDedupTests {
    /// Regression for the navigation-bar back button vanishing from `ui`.
    ///
    /// On a pushed screen `deviceFetchSpecialElement: 0` returns the back button
    /// as the root, so the root token aliases a real, distinct element. The walk
    /// used to seed `visited` with the raw root token and then dropped that
    /// element as "already seen"; the composite (token, summary, role) key keeps
    /// it while still collapsing the genuine repeats the deep child walk emits.
    @Test("an element whose token aliases the root is not dropped")
    func rootTokenAliasDoesNotDropElement() async throws {
        let rootToken = Data(repeating: 0x80, count: 20)
        let otherToken = Data(repeating: 0x02, count: 20)
        let client = AXAuditClient(transport: AliasingHierarchyTransport(
            rootToken: rootToken,
            nodes: [
                .init(token: rootToken, summary: "sim-use Playground Button", role: "Button"),
                .init(token: otherToken, summary: "Tap Test Header", role: "Header"),
            ]
        ))

        let elements = try await DeviceTreeFetcher(client: client).fetchTree()

        #expect(elements.contains { $0.role == "Button" && $0.summary.contains("Playground") })
        #expect(elements.contains { $0.role == "Header" })
    }

    @Test("genuine repeats (same token, summary and role) still collapse")
    func genuineRepeatsCollapse() async throws {
        let rootToken = Data(repeating: 0x80, count: 20)
        let dupToken = Data(repeating: 0x03, count: 20)
        let client = AXAuditClient(transport: AliasingHierarchyTransport(
            rootToken: rootToken,
            nodes: [
                .init(token: dupToken, summary: "Row", role: "Button"),
                .init(token: dupToken, summary: "Row", role: "Button"),
            ]
        ))

        let elements = try await DeviceTreeFetcher(client: client).fetchTree()

        #expect(elements.filter { $0.summary == "Row" }.count == 1)
    }
}

/// Serves one fixed hierarchy for the root element and nothing for anything
/// else, so a deep walk terminates. The root's own token is reused by one of
/// the returned nodes, reproducing the daemon's root/back-button aliasing.
private struct AliasingHierarchyTransport: DTXInvoking {
    struct Node {
        let token: Data
        let summary: String
        let role: String
    }

    let rootToken: Data
    let nodes: [Node]

    func invoke(_ selector: String, arguments: [AXAuditValue], expectsReply: Bool) async throws -> AXAuditValue {
        switch selector {
        case "deviceFetchSpecialElement:":
            return AXAuditElement(token: rootToken).encoded
        case "deviceElement:valueForAttribute:":
            // Return the hierarchy only when asked about the root element; other
            // elements report no children so the walk terminates.
            guard let requested = arguments.first.flatMap(AXAuditElement.init(payload:)),
                  requested.token == rootToken else { return .null }
            return .list(nodes.map { node in
                .object(tag: "AXAuditNode_v1", fields: [
                    "AuditElementValue_v1": .object(tag: "AXAuditElement_v1", fields: [
                        "PlatformElementValue_v1": .scalar(node.token),
                    ]),
                    "HumanReadableDescriptionValue_v1": .scalar(node.summary),
                    "HumanReadableRoleDescriptionValue_v1": .scalar(node.role),
                    "IsIgnoredValue_v1": .scalar(0),
                ])
            })
        default:
            return .null
        }
    }
}
