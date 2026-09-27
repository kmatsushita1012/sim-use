// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// Spreads requests over several DTX connections.
///
/// One connection saturates at roughly eight in-flight requests — the daemon
/// serialises them on its side, so raising the in-flight count alone buys
/// nothing. Whether separate connections are served in parallel is a property
/// of the daemon, and this type is how that gets exercised.
public struct PooledTransport: DTXInvoking {
    private let connections: [DTXConnection]
    private let cursor = OSAllocatedUnfairLock(initialState: 0)

    public init(connections: [DTXConnection]) {
        precondition(!connections.isEmpty)
        self.connections = connections
    }

    public func invoke(
        _ selector: String,
        arguments: [AXAuditValue],
        expectsReply: Bool
    ) async throws -> AXAuditValue {
        try await next().invoke(selector, arguments: arguments, expectsReply: expectsReply)
    }

    private func next() -> DTXConnection {
        let index = cursor.withLock { cursor -> Int in
            cursor = (cursor + 1) % connections.count
            return cursor
        }
        return connections[index]
    }
}
