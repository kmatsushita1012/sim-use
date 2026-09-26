// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import iOSDeviceBackend

/// The daemon accepts a malformed element without complaining — it performs
/// nothing and, since actions are fire-and-forget, the caller sees success.
/// These tests pin the envelope shape so that failure mode cannot come back.
@Suite("AXAudit payload envelope")
struct AXAuditPayloadTests {
    private let token = Data([0x1A, 0x36, 0x00, 0x00, 0x00, 0x76, 0xAA, 0x16])

    @Test("element carries its token inside PlatformElementValue_v1")
    func elementTokenNesting() throws {
        let encoded = AXAuditElement(token: token).encoded.propertyList as? [String: Any]
        let outer = try #require(encoded)
        #expect(outer["ObjectType"] as? String == "AXAuditElement_v1")

        let passthrough = try #require(outer["Value"] as? [String: Any])
        #expect(passthrough["ObjectType"] as? String == "passthrough")

        let fields = try #require(passthrough["Value"] as? [String: Any])
        // The regression: the token must not appear as a sibling of
        // PlatformElementValue_v1, and PlatformElementValue_v1 must not be an
        // envelope with no Value of its own.
        #expect(fields["Value"] == nil)

        let platform = try #require(fields["PlatformElementValue_v1"] as? [String: Any])
        #expect(platform["ObjectType"] as? String == "passthrough")
        #expect(platform["Value"] as? Data == token)
    }

    @Test("an element survives a round trip through the wire representation")
    func elementRoundTrip() throws {
        let original = AXAuditElement(token: token)
        let decoded = AXAuditValue(propertyList: original.encoded.propertyList)
        #expect(AXAuditElement(payload: decoded) == original)
    }

    @Test("activate is the action the device advertises")
    func activateDescriptor() throws {
        let fields = try #require(
            (AXAuditAttribute.activate.encoded.propertyList as? [String: Any])?["Value"] as? [String: Any]
        )
        let inner = try #require(fields["Value"] as? [String: Any])
        #expect((inner["AttributeNameValue_v1"] as? [String: Any])?["Value"] as? String == "AXAction-2010")
        #expect((inner["PerformsActionValue_v1"] as? [String: Any])?["Value"] as? Int == 1)
        #expect((inner["ValueTypeValue_v1"] as? [String: Any])?["Value"] as? Int == 1)
    }

    @Test("scroll actions use the codes read back from the daemon")
    func scrollDescriptors() {
        #expect(AXAuditAttribute.scrollDown.name == "AXAction-2006")
        #expect(AXAuditAttribute.scrollUp.name == "AXAction-2007")
        #expect(AXAuditAttribute.scrollDown.isScrollAction)
        #expect(!AXAuditAttribute.activate.isScrollAction)
    }

    @Test("hierarchy nodes decode into elements with role and label")
    func hierarchyDecoding() throws {
        let node = AXAuditValue.object(tag: "AXAuditNode_v1", fields: [
            "AuditElementValue_v1": AXAuditElement(token: token).encoded,
            "HumanReadableDescriptionValue_v1": .scalar("Chats Button, Selected"),
            "HumanReadableRoleDescriptionValue_v1": .scalar("Button"),
            "IsIgnoredValue_v1": .scalar(false),
        ])
        let reply = AXAuditValue.passthrough(.fields(["ChildrenValue_v1": .list([node])]))

        let found = reply.descendants(taggedWith: "AXAuditNode_v1")
        #expect(found.count == 1)
        #expect(found[0]["HumanReadableRoleDescriptionValue_v1"]?.stringValue == "Button")
        #expect(AXAuditElement(payload: try #require(found[0]["AuditElementValue_v1"]))?.token == token)
    }
}
