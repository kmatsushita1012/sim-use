// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The self-describing envelope every value on the axAuditDaemon wire is
/// wrapped in: `{"ObjectType": <tag>, "Value": <payload>}`.
///
/// Modelling it as a type rather than hand-built dictionaries is deliberate.
/// The reference Python client mis-nests the element token one level up
/// (`PlatformElementValue_v1` gets an envelope with no `Value`, and the token
/// lands in a sibling key); the daemon then receives an empty element, performs
/// nothing, and — because the call is fire-and-forget — reports success.
public indirect enum AXAuditValue: Equatable, Sendable {
    case passthrough(AXAuditValue)
    case object(tag: String, value: AXAuditValue)
    case fields([String: AXAuditValue])
    case string(String)
    case int(Int)
    case bool(Bool)
    case data(Data)
    case list([AXAuditValue])
    case null

    private enum Key {
        static let objectType = "ObjectType"
        static let value = "Value"
        static let passthrough = "passthrough"
    }
}

// MARK: - Encoding

public extension AXAuditValue {
    /// Property-list representation handed to `NSKeyedArchiver`.
    var propertyList: Any {
        switch self {
        case let .passthrough(inner):
            return [Key.objectType: Key.passthrough, Key.value: inner.propertyList]
        case let .object(tag, value):
            return [Key.objectType: tag, Key.value: value.propertyList]
        case let .fields(fields):
            return fields.mapValues(\.propertyList)
        case let .string(string):
            return string
        case let .int(int):
            return int
        case let .bool(bool):
            return bool
        case let .data(data):
            return data
        case let .list(values):
            return values.map(\.propertyList)
        case .null:
            return NSNull()
        }
    }

    /// `passthrough`-wrapped scalar, the shape the daemon expects for every
    /// leaf inside an object's field dictionary.
    static func scalar(_ string: String) -> AXAuditValue { .passthrough(.string(string)) }
    static func scalar(_ int: Int) -> AXAuditValue { .passthrough(.int(int)) }
    static func scalar(_ bool: Bool) -> AXAuditValue { .passthrough(.bool(bool)) }
    static func scalar(_ data: Data) -> AXAuditValue { .passthrough(.data(data)) }

    /// A tagged object whose fields are each `passthrough`-wrapped.
    static func object(tag: String, fields: [String: AXAuditValue]) -> AXAuditValue {
        .object(tag: tag, value: .passthrough(.fields(fields)))
    }
}

// MARK: - Decoding

public extension AXAuditValue {
    init(propertyList: Any) {
        if let dictionary = propertyList as? [String: Any] {
            if let tag = dictionary[Key.objectType] as? String {
                let inner = dictionary[Key.value].map { AXAuditValue(propertyList: $0) } ?? .null
                self = tag == Key.passthrough ? .passthrough(inner) : .object(tag: tag, value: inner)
                return
            }
            self = .fields(dictionary.mapValues { AXAuditValue(propertyList: $0) })
            return
        }
        if let values = propertyList as? [Any] {
            self = .list(values.map { AXAuditValue(propertyList: $0) })
            return
        }
        if let data = propertyList as? Data { self = .data(data); return }
        if let string = propertyList as? String { self = .string(string); return }
        if let number = propertyList as? NSNumber {
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .int(number.intValue)
            return
        }
        self = .null
    }

    /// Strips `passthrough` layers so callers can read a leaf without walking
    /// the envelope by hand.
    var unwrapped: AXAuditValue {
        if case let .passthrough(inner) = self { return inner.unwrapped }
        return self
    }

    var stringValue: String? {
        if case let .string(string) = unwrapped { return string }
        return nil
    }

    var intValue: Int? {
        switch unwrapped {
        case let .int(int): return int
        case let .bool(bool): return bool ? 1 : 0
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch unwrapped {
        case let .bool(bool): return bool
        case let .int(int): return int != 0
        default: return nil
        }
    }

    var dataValue: Data? {
        if case let .data(data) = unwrapped { return data }
        return nil
    }

    subscript(field: String) -> AXAuditValue? {
        switch unwrapped {
        case let .fields(fields): return fields[field]
        case let .object(_, value): return value[field]
        default: return nil
        }
    }

    /// Depth-first search for every object carrying `tag`, used to pull nodes
    /// out of a hierarchy reply without modelling the whole reply shape.
    func descendants(taggedWith tag: String) -> [AXAuditValue] {
        var found: [AXAuditValue] = []
        walk { value in
            if case let .object(objectTag, _) = value, objectTag == tag { found.append(value) }
        }
        return found
    }

    private func walk(_ visit: (AXAuditValue) -> Void) {
        visit(self)
        switch self {
        case let .passthrough(inner): inner.walk(visit)
        case let .object(_, value): value.walk(visit)
        case let .fields(fields): fields.values.forEach { $0.walk(visit) }
        case let .list(values): values.forEach { $0.walk(visit) }
        default: break
        }
    }
}
