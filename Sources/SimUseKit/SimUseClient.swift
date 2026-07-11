// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl
import SimUseCore
import iOSSimBackend

/// A serial, application-facing client for simulator operations.
///
/// The client deliberately does not start a CLI process, parse command-line
/// arguments, or use the daemon socket. All operations call the existing
/// backend implementations directly. Main-actor isolation matches
/// FBSimulatorControl's requirement and also serializes operations so two
/// concurrent requests cannot interleave HID events for one simulator.
@MainActor
public final class SimUseClient {
    private var hidSessions: [String: HIDInteractor.Session] = [:]

    public init() {}

    /// Opens (or reuses) a connection for one simulator. The returned
    /// session is a lightweight handle; the HID object remains owned by the
    /// client and is invalidated automatically when an event fails.
    public func openSession(for deviceID: SimulatorID) async throws -> SimulatorSession {
        _ = try await session(for: deviceID)
        return SimulatorSession(deviceID: deviceID, client: self)
    }

    /// Sends a typed command request directly through its backend adapter.
    public func execute<Request: SimUseRequest>(
        _ request: Request,
        on deviceID: SimulatorID
    ) async throws -> Request.Output {
        do {
            return try await request.execute(on: deviceID, using: self)
        } catch {
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }

    /// Compatibility escape hatch for every existing command that already
    /// conforms to `SimUseExecutableCommand`. This is a typed generic API:
    /// the caller receives that command's concrete `ExecutionResult`, while
    /// the command is executed in-process without ArgumentParser parsing or
    /// daemon transport. New backend commands automatically work here before
    /// a dedicated application-facing request is added.
    public func execute<Command: SimUseExecutableCommand>(
        _ command: Command,
        on deviceID: SimulatorID
    ) async throws -> Command.ExecutionResult {
        var command = command
        do {
            try command.resolveDeferredArguments()
            try command.validate()
            return try await command.execute()
        } catch {
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }

    /// Sends a sequence of HID events over one cached simulator session.
    /// The session is reused across calls and discarded when an event fails,
    /// allowing the next call to establish a fresh connection after reboot.
    public func send(
        _ events: [HIDEvent],
        on deviceID: SimulatorID
    ) async throws {
        guard !events.isEmpty else { return }

        do {
            var session = try await session(for: deviceID)
            let logger = SimUseLogger()
            for event in events {
                session = try await HIDInteractor.performHIDEventReturningSession(
                    event.makeBackendEvent(),
                    in: session,
                    logger: logger
                )
                hidSessions[deviceID.rawValue] = session
            }
        } catch {
            hidSessions.removeValue(forKey: deviceID.rawValue)
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }

    /// Explicitly drops the cached HID session for one simulator.
    public func invalidateSession(for deviceID: SimulatorID) {
        hidSessions.removeValue(forKey: deviceID.rawValue)
        HIDInteractor.clearHIDConnection(for: deviceID.rawValue)
    }

    /// Drops all cached HID sessions owned by this client.
    public func invalidateAllSessions() {
        hidSessions.removeAll()
        HIDInteractor.clearHIDConnections()
    }

    fileprivate func session(for deviceID: SimulatorID) async throws -> HIDInteractor.Session {
        if let session = hidSessions[deviceID.rawValue] {
            return session
        }
        let session = try await HIDInteractor.makeSession(
            for: deviceID.rawValue,
            logger: SimUseLogger()
        )
        hidSessions[deviceID.rawValue] = session
        return session
    }
}

@MainActor
public final class SimulatorSession {
    public let deviceID: SimulatorID
    private unowned let client: SimUseClient

    fileprivate init(deviceID: SimulatorID, client: SimUseClient) {
        self.deviceID = deviceID
        self.client = client
    }

    public func send(_ events: [HIDEvent]) async throws {
        try await client.send(events, on: deviceID)
    }

    public func invalidate() {
        client.invalidateSession(for: deviceID)
    }
}

public struct SimulatorID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}

public protocol SimUseRequest {
    associatedtype Output: Sendable

    @MainActor
    func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> Output
}

/// Application-facing HID events. The underlying idb event type stays inside
/// the adapter target.
public enum HIDEvent: Sendable {
    case touchDown(x: Double, y: Double)
    case touchUp(x: Double, y: Double)
    case tap(x: Double, y: Double)
    case swipe(startX: Double, startY: Double, endX: Double, endY: Double, delta: Double, duration: Double)
    case keyDown(UInt32)
    case keyUp(UInt32)
    case buttonDown(UInt32)
    case buttonUp(UInt32)
    case delay(TimeInterval)

    fileprivate func makeBackendEvent() -> FBSimulatorHIDEvent {
        switch self {
        case let .touchDown(x, y):
            return FBSimulatorHIDEvent.touchDownAt(x: x, y: y)
        case let .touchUp(x, y):
            return FBSimulatorHIDEvent.touchUpAt(x: x, y: y)
        case let .tap(x, y):
            return FBSimulatorHIDEvent.tapAt(x: x, y: y)
        case let .swipe(startX, startY, endX, endY, delta, duration):
            return FBSimulatorHIDEvent.swipe(
                startX,
                yStart: startY,
                xEnd: endX,
                yEnd: endY,
                delta: delta,
                duration: duration
            )
        case let .keyDown(keyCode):
            return FBSimulatorHIDEvent.keyDown(keyCode)
        case let .keyUp(keyCode):
            return FBSimulatorHIDEvent.keyUp(keyCode)
        case let .buttonDown(button):
            return FBSimulatorHIDEvent.buttonDown(FBSimulatorHIDButton(rawValue: Int(button)))
        case let .buttonUp(button):
            return FBSimulatorHIDEvent.buttonUp(FBSimulatorHIDButton(rawValue: Int(button)))
        case let .delay(seconds):
            return FBSimulatorHIDEvent.delay(seconds)
        }
    }
}
