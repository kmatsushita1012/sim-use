// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Wire format for Apple's DTX message protocol, as spoken by the developer
/// services behind a lockdown connection.
///
/// Byte-level layout only — no I/O — so the framing can be tested without a
/// device. Layout matches idb's `FBInstrumentsClient`, which in turn follows
/// the ios_instruments_client reverse engineering.
enum DTXFraming {
    static let magic: UInt32 = 0x1F3D_5B79
    static let headerSize = 32

    struct Header: Equatable {
        var magic: UInt32 = DTXFraming.magic
        var headerLength: UInt32 = UInt32(DTXFraming.headerSize)
        var fragmentID: UInt16 = 0
        var fragmentCount: UInt16 = 1
        var length: UInt32 = 0
        var identifier: UInt32 = 0
        var conversationIndex: UInt32 = 0
        var channelCode: UInt32 = 0
        var expectsReply: UInt32 = 0

        /// Requests and unsolicited events start a conversation at index zero.
        /// Only a positive index can be correlated with a pending request.
        var isReply: Bool { conversationIndex > 0 }

        var encoded: Data {
            var data = Data(capacity: DTXFraming.headerSize)
            data.appendLittleEndian(magic)
            data.appendLittleEndian(headerLength)
            data.appendLittleEndian(fragmentID)
            data.appendLittleEndian(fragmentCount)
            data.appendLittleEndian(length)
            data.appendLittleEndian(identifier)
            data.appendLittleEndian(conversationIndex)
            data.appendLittleEndian(channelCode)
            data.appendLittleEndian(expectsReply)
            return data
        }

        init() {}

        init?(decoding data: Data) {
            guard data.count >= DTXFraming.headerSize else { return nil }
            var cursor = DataCursor(data)
            magic = cursor.readUInt32()
            headerLength = cursor.readUInt32()
            fragmentID = cursor.readUInt16()
            fragmentCount = cursor.readUInt16()
            length = cursor.readUInt32()
            identifier = cursor.readUInt32()
            conversationIndex = cursor.readUInt32()
            channelCode = cursor.readUInt32()
            expectsReply = cursor.readUInt32()
            guard magic == DTXFraming.magic else { return nil }
        }
    }

    /// `flags` carries the compression nibble; anything non-zero means the
    /// payload is compressed, which this client never negotiates.
    private struct PayloadHeader {
        var flags: UInt32
        var auxiliaryLength: UInt32
        var totalLength: UInt64

        var encoded: Data {
            var data = Data(capacity: 16)
            data.appendLittleEndian(flags)
            data.appendLittleEndian(auxiliaryLength)
            data.appendLittleEndian(totalLength)
            return data
        }
    }

    private static let argumentMagic: UInt64 = 0x1F0
    private static let emptyDictionaryKey: UInt32 = 10
    private static let objectArgumentType: UInt32 = 2

    static func encodeRequest(
        selector: String,
        arguments: [Any],
        identifier: UInt32,
        channelCode: UInt32 = 0,
        expectsReply: Bool
    ) throws -> Data {
        let auxiliary = try encodeAuxiliary(arguments)
        let selectorData = try NSKeyedArchiver.archivedData(withRootObject: selector, requiringSecureCoding: false)

        let payloadHeader = PayloadHeader(
            flags: 0x2 | (expectsReply ? 0x1000 : 0),
            auxiliaryLength: UInt32(auxiliary.count),
            totalLength: UInt64(auxiliary.count + selectorData.count)
        )
        var header = Header()
        header.length = UInt32(16 + payloadHeader.totalLength)
        header.identifier = identifier
        header.channelCode = channelCode
        header.expectsReply = expectsReply ? 1 : 0

        return header.encoded + payloadHeader.encoded + auxiliary + selectorData
    }

    private static func encodeAuxiliary(_ arguments: [Any]) throws -> Data {
        guard !arguments.isEmpty else { return Data() }
        var body = Data()
        for argument in arguments {
            let archived = try NSKeyedArchiver.archivedData(withRootObject: argument, requiringSecureCoding: false)
            body.appendLittleEndian(emptyDictionaryKey)
            body.appendLittleEndian(objectArgumentType)
            body.appendLittleEndian(UInt32(archived.count))
            body.append(archived)
        }
        var data = Data()
        data.appendLittleEndian(argumentMagic)
        data.appendLittleEndian(UInt64(body.count))
        data.append(body)
        return data
    }

    struct Reply {
        var returnValue: Any?
        var auxiliaryValues: [Any]
    }

    static func decodePayload(_ payload: Data) throws -> Reply {
        var cursor = DataCursor(payload)
        let flags = cursor.readUInt32()
        let auxiliaryLength = Int(cursor.readUInt32())
        let totalLength = Int(cursor.readUInt64())
        guard (flags & 0xFF000) >> 12 == 0 else { throw DTXError.compressedPayload }

        let auxiliary = cursor.read(auxiliaryLength)
        let returnValueData = cursor.read(max(0, totalLength - auxiliaryLength))

        return Reply(
            returnValue: returnValueData.isEmpty ? nil : try unarchive(returnValueData),
            auxiliaryValues: auxiliary.isEmpty ? [] : try decodeAuxiliary(auxiliary)
        )
    }

    private static func decodeAuxiliary(_ data: Data) throws -> [Any] {
        guard data.count >= 16 else { return [] }
        var cursor = DataCursor(data)
        _ = cursor.readUInt64()
        _ = cursor.readUInt64()

        var values: [Any] = []
        while cursor.remaining > 12 {
            _ = cursor.readUInt32()
            let type = cursor.readUInt32()
            guard type == objectArgumentType else { throw DTXError.unsupportedArgumentType(type) }
            let length = Int(cursor.readUInt32())
            values.append(try unarchive(cursor.read(length)))
        }
        return values
    }

    /// The daemon's replies are plain plist containers — the `AXAudit*` names
    /// are tags inside dictionaries, not archived ObjC classes — so allowing
    /// the container and leaf classes is sufficient.
    private static func unarchive(_ data: Data) throws -> Any {
        let classes: [AnyClass] = [
            NSDictionary.self, NSArray.self, NSString.self, NSNumber.self,
            NSData.self, NSDate.self, NSError.self, NSNull.self,
        ]
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) else {
            throw DTXError.undecodableValue
        }
        if let error = value as? NSError { throw error }
        return value
    }
}

enum DTXError: Error, LocalizedError, CustomStringConvertible {
    case compressedPayload
    case unsupportedArgumentType(UInt32)
    case undecodableValue
    case connectionClosed

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .compressedPayload: return "the device negotiated a compressed DTX payload"
        case let .unsupportedArgumentType(type): return "unsupported DTX argument type \(type)"
        case .undecodableValue: return "could not decode a DTX value"
        case .connectionClosed: return "the DTX connection closed"
        }
    }
}

private struct DataCursor {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func read(_ count: Int) -> Data {
        let end = min(offset + count, data.endIndex)
        defer { offset = end }
        return data[offset..<end]
    }

    mutating func readUInt16() -> UInt16 { readInteger() }
    mutating func readUInt32() -> UInt32 { readInteger() }
    mutating func readUInt64() -> UInt64 { readInteger() }

    private mutating func readInteger<T: FixedWidthInteger>() -> T {
        let width = MemoryLayout<T>.size
        let slice = read(width)
        guard slice.count == width else { return 0 }
        return slice.reduce(T(0)) { accumulated, byte in
            (accumulated >> 8) | (T(byte) << ((width - 1) * 8))
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
