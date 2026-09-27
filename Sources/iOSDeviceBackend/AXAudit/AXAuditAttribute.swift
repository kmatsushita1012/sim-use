// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A request descriptor for `deviceElement:valueForAttribute:` and
/// `deviceElement:performAction:withValue:`.
///
/// The daemon advertises the attributes it supports per inspector section, but
/// the advertised list is not exhaustive — `Traits` is absent from it yet reads
/// back fine — so the names below are the ones measured to work rather than the
/// ones announced. `Frame` is deliberately missing: iOS serves no geometry on
/// this channel at all (Xcode's own Accessibility Inspector shows no Frame row
/// for a physical device either).
public struct AXAuditAttribute: Equatable, Sendable {
    public let name: String
    public let humanReadableName: String
    public let performsAction: Bool
    public let isSettable: Bool
    public let valueType: Int

    public init(
        name: String,
        humanReadableName: String? = nil,
        performsAction: Bool = false,
        isSettable: Bool = false,
        valueType: Int = 0
    ) {
        self.name = name
        self.humanReadableName = humanReadableName ?? name
        self.performsAction = performsAction
        self.isSettable = isSettable
        self.valueType = valueType
    }

    public var encoded: AXAuditValue {
        .object(tag: "AXAuditElementAttribute_v1", fields: [
            "AttributeNameValue_v1": .scalar(name),
            "HumanReadableNameValue_v1": .scalar(humanReadableName),
            "DisplayAsTree_v1": .scalar(0),
            "IsInternal_v1": .scalar(0),
            "PerformsActionValue_v1": .scalar(performsAction ? 1 : 0),
            "SettableValue_v1": .scalar(isSettable ? 1 : 0),
            "ValueTypeValue_v1": .scalar(valueType),
        ])
    }
}

// MARK: - Readable attributes

public extension AXAuditAttribute {
    static let label = AXAuditAttribute(name: "Label")
    static let value = AXAuditAttribute(name: "Value")
    static let hint = AXAuditAttribute(name: "Hint")
    static let identifier = AXAuditAttribute(name: "Identifier")
    static let traits = AXAuditAttribute(name: "Traits")
    static let traitsHumanReadable = AXAuditAttribute(name: "TraitsHumanReadable")
    static let className = AXAuditAttribute(name: "ElementClassName")
    static let hierarchy = AXAuditAttribute(name: "_AXHierarchyElementsAttribute")
}

// MARK: - Actions

public extension AXAuditAttribute {
    /// Tapping. The numeric codes are the daemon's own action identifiers,
    /// read back from the Actions section of a focus event.
    static let activate = action(code: 2010, humanReadableName: "Activate")
    static let scrollDown = action(code: 2006, humanReadableName: "Scroll down")
    static let scrollUp = action(code: 2007, humanReadableName: "Scroll up")

    static func action(code: Int, humanReadableName: String) -> AXAuditAttribute {
        AXAuditAttribute(
            name: "AXAction-\(code)",
            humanReadableName: humanReadableName,
            performsAction: true,
            valueType: 1
        )
    }

    /// App-defined actions (LINE's `Pin chat`, `Delete`, …). Their names embed a
    /// live pointer, so they are only valid for the session that reported them.
    static func custom(name: String, humanReadableName: String) -> AXAuditAttribute {
        AXAuditAttribute(name: name, humanReadableName: humanReadableName, performsAction: true, valueType: 1)
    }

    var isScrollAction: Bool { self == .scrollDown || self == .scrollUp }
}
