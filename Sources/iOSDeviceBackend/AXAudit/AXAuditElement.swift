// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A handle to one on-device accessibility element.
///
/// `token` is the daemon's `PlatformElementValue_v1` — an opaque 20-byte blob
/// that encodes a live pointer, so it is only meaningful within the session
/// that produced it, and only while the element is still on screen.
///
/// The two APIs disagree about staleness, which the call sites must respect:
/// `performAction` still works on a token captured many focus steps earlier,
/// while `valueForAttribute` returns nil for anything but a freshly returned or
/// currently focused element. Re-focusing a stale token is worse than useless —
/// table-view cells are recycled, so it lands on a different row and reads as a
/// selection.
public struct AXAuditElement: Equatable, Hashable, Sendable {
    public let token: Data

    public init(token: Data) {
        self.token = token
    }

    public var encoded: AXAuditValue {
        .object(tag: "AXAuditElement_v1", fields: [
            "PlatformElementValue_v1": .scalar(token),
        ])
    }

    /// Recovers an element from a reply. Nested `AuditElementValue_v1` wrappers
    /// appear inside hierarchy nodes, so the search is depth-first rather than
    /// a fixed key path.
    public init?(payload: AXAuditValue) {
        guard let token = Self.firstToken(in: payload) else { return nil }
        self.init(token: token)
    }

    private static func firstToken(in value: AXAuditValue) -> Data? {
        if let token = value["PlatformElementValue_v1"]?.dataValue { return token }
        switch value.unwrapped {
        case let .fields(fields):
            for field in fields.values {
                if let token = firstToken(in: field) { return token }
            }
        case let .list(values):
            for element in values {
                if let token = firstToken(in: element) { return token }
            }
        case let .object(_, inner):
            return firstToken(in: inner)
        default:
            break
        }
        return nil
    }
}

/// One node of the hierarchy reply. The daemon reports the view tree, so most
/// nodes are plain containers; a non-empty `role` marks the ones that are real
/// accessibility elements.
public struct AXAuditNode: Equatable, Sendable {
    public let element: AXAuditElement
    public let summary: String
    public let role: String
    public let identifier: String?
    public let isIgnored: Bool

    public init(element: AXAuditElement, summary: String, role: String, identifier: String? = nil, isIgnored: Bool) {
        self.element = element
        self.summary = summary
        self.role = role
        self.identifier = identifier
        self.isIgnored = isIgnored
    }

    public var isAccessibilityElement: Bool { !role.isEmpty && !isIgnored }

    /// Dedup identity for the tree walk. The daemon reuses an element token for
    /// distinct logical elements (notably `deviceFetchSpecialElement: 0` aliases
    /// the navigation-bar back button on a pushed screen), so the token alone is
    /// not a safe key; the summary and role disambiguate them. `\u{1}` cannot
    /// appear in a human-readable summary or role, so it is a safe separator.
    var identityKey: String {
        "\(element.token.base64EncodedString())\u{1}\(summary)\u{1}\(role)"
    }
}
