// SPDX-License-Identifier: Apache-2.0
import Darwin
import FBControlCore
import FBDeviceControl
import Foundation
import os

/// A DTX control channel over one lockdown service connection.
///
/// Requests are pipelined: each carries its own message identifier and a
/// reader task hands replies back to whoever is waiting on that identifier. A
/// tree walk can therefore have many hierarchy reads in flight, which is most
/// of the difference between a snappy `ui` and a sluggish one.
///
/// This is only safe because the transport talks to the raw socket. Reading and
/// writing `FBAMDServiceConnection` itself from two threads fails the socket
/// with `Protocol not supported`; a plain fd is full duplex.
///
/// The daemon also pushes unsolicited events (focus changes, app state) down
/// the same channel. Each peer allocates identifiers independently, so an event
/// can collide with a pending request identifier; `conversationIndex` separates
/// new messages from replies and events are dropped.
public final class DTXConnection: DTXInvoking, Sendable {
    private struct State {
        var pending: [UInt32: CheckedContinuation<DTXFraming.Reply, Error>] = [:]
        var nextIdentifier: UInt32 = 1
        var isClosed = false
        var reader: Task<Void, Never>?
    }

    private let socket: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Held across the blocking write so two senders cannot interleave frames.
    private let writeGate = OSAllocatedUnfairLock(initialState: ())

    /// Talks to the raw socket rather than `FBAMDServiceConnection`'s own
    /// send/receive. Those push bytes through the connection's SSL context,
    /// but this daemon wants the DTX stream in plaintext once lockdown has
    /// finished starting the service — encrypted frames make the device hang
    /// up on the first message.
    public init(connection: FBAMDServiceConnection) throws {
        guard let getSocket = connection.calls.ServiceConnectionGetSocket,
              let reference = connection.connection else {
            throw DTXError.connectionClosed
        }
        socket = getSocket(reference)
        guard socket >= 0 else { throw DTXError.connectionClosed }
    }

    /// Announces host capabilities. The daemon answers with its channel list,
    /// which this client does not need — everything it calls lives on the
    /// control channel.
    public func handshake() throws {
        try write(try DTXFraming.encodeRequest(
            selector: "_notifyOfPublishedCapabilities:",
            arguments: [["com.apple.private.DTXBlockCompression": 2, "com.apple.private.DTXConnection": 1]],
            identifier: claimIdentifier(),
            expectsReply: false
        ))
        startReading()
    }

    public func invoke(
        _ selector: String,
        arguments: [AXAuditValue],
        expectsReply: Bool
    ) async throws -> AXAuditValue {
        let identifier = claimIdentifier()
        let request = try DTXFraming.encodeRequest(
            selector: selector,
            arguments: arguments.map(\.propertyList),
            identifier: identifier,
            expectsReply: expectsReply
        )

        guard expectsReply else {
            try write(request)
            return .null
        }

        let reply: DTXFraming.Reply = try await withCheckedThrowingContinuation { continuation in
            let accepted = state.withLock { state -> Bool in
                guard !state.isClosed else { return false }
                state.pending[identifier] = continuation
                return true
            }
            guard accepted else {
                continuation.resume(throwing: DTXError.connectionClosed)
                return
            }
            do {
                try write(request)
            } catch {
                resume(identifier: identifier, with: .failure(error))
            }
        }
        guard let returnValue = reply.returnValue else { return .null }
        return AXAuditValue(propertyList: returnValue)
    }

    public func close(because error: Error? = nil) {
        let (waiting, reader) = state.withLock { state -> ([CheckedContinuation<DTXFraming.Reply, Error>], Task<Void, Never>?) in
            state.isClosed = true
            let waiting = Array(state.pending.values)
            state.pending.removeAll()
            let reader = state.reader
            state.reader = nil
            return (waiting, reader)
        }
        reader?.cancel()
        let reason = error ?? DTXError.connectionClosed
        waiting.forEach { $0.resume(throwing: reason) }
    }

    // MARK: - Socket

    private func claimIdentifier() -> UInt32 {
        state.withLock { state in
            state.nextIdentifier += 1
            return state.nextIdentifier
        }
    }

    private func write(_ data: Data) throws {
        try writeGate.withLock { _ in
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(socket, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard written > 0 else { throw DTXError.connectionClosed }
                    offset += written
                }
            }
        }
    }

    private func read(exactly count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(socket, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            guard received > 0 else { throw DTXError.connectionClosed }
            offset += received
        }
        return Data(buffer)
    }

    /// Detached because the loop parks in a blocking `read(2)` for the life of
    /// the session; leaving it on a structured child would hold whichever task
    /// spawned it hostage.
    private func startReading() {
        let reader = Task.detached(priority: .userInitiated) { [self] in
            while !Task.isCancelled {
                do {
                    let (header, payload) = try readMessage()
                    guard header.isReply else { continue }
                    let reply = payload.isEmpty
                        ? DTXFraming.Reply(returnValue: nil, auxiliaryValues: [])
                        : try DTXFraming.decodePayload(payload)
                    resume(identifier: header.identifier, with: .success(reply))
                } catch {
                    close(because: error)
                    return
                }
            }
        }
        state.withLock { $0.reader = reader }
    }

    private func readMessage() throws -> (DTXFraming.Header, Data) {
        var payload = Data()
        var header = DTXFraming.Header()
        header.fragmentCount = .max

        while header.fragmentID < header.fragmentCount - 1 {
            guard let decoded = DTXFraming.Header(decoding: try read(exactly: DTXFraming.headerSize)) else {
                throw DTXError.connectionClosed
            }
            header = decoded
            // The lead fragment of a split message carries sizing only.
            if header.fragmentCount > 1, header.fragmentID == 0 { continue }
            payload.append(try read(exactly: Int(header.length)))
        }
        return (header, payload)
    }

    private func resume(identifier: UInt32, with result: Result<DTXFraming.Reply, Error>) {
        let continuation = state.withLock { $0.pending.removeValue(forKey: identifier) }
        continuation?.resume(with: result)
    }
}
