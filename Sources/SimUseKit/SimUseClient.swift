// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl
import SimUseCore
import iOSSimBackend

/// A concurrency-safe, application-facing client for simulator operations.
///
/// The client deliberately does not start a CLI process, parse command-line
/// arguments, or use the daemon socket. All operations call the existing
/// backend implementations directly. FBSimulatorControl's state is isolated
/// behind one worker actor per simulator. The private framework calls
/// themselves run on MainActor, as required by the simulator runtime.
@MainActor
public final class SimUseClient {
    private var workers: [String: SimulatorWorker] = [:]

    nonisolated public init() {}

    /// Opens (or reuses) a connection for one simulator. The returned
    /// session is a lightweight handle; the HID object remains owned by the
    /// client and is invalidated automatically when an event fails.
    public func openSession(for deviceID: SimulatorID) async throws -> SimulatorSession {
        try validate(deviceID)
        let worker = worker(for: deviceID)
        try await worker.open()
        return SimulatorSession(deviceID: deviceID, worker: worker)
    }

    /// Sends a typed command request directly through its backend adapter.
    public func execute<Request: SimUseRequest>(
        _ request: Request,
        on deviceID: SimulatorID
    ) async throws -> Request.Output {
        try validate(deviceID)
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
        try validate(deviceID)
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
        _ = try await sendTimed(events, on: deviceID)
    }

    /// Sends events over one cached session and records the time at which each
    /// event has completed. The returned values measure the public API call,
    /// including backend stabilization and transport time.
    public func sendTimed(
        _ events: [HIDEvent],
        on deviceID: SimulatorID
    ) async throws -> [HIDEventTiming] {
        try validate(deviceID)
        guard !events.isEmpty else { return [] }
        try validate(events)

        do {
            return try await worker(for: deviceID).sendTimed(events)
        } catch {
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }

    /// Explicitly drops the cached HID session for one simulator.
    public func invalidateSession(for deviceID: SimulatorID) async {
        worker(for: deviceID).invalidate()
    }

    /// Drops all cached HID sessions owned by this client.
    public func invalidateAllSessions() async {
        for worker in workers.values {
            worker.invalidate()
        }
        workers.removeAll()
        HIDInteractor.clearHIDConnections()
    }

    func resetLiveness(for deviceID: SimulatorID, to snapshot: AppSnapshot) async {
        worker(for: deviceID).resetLiveness(to: snapshot, now: Date())
    }

    private func worker(for deviceID: SimulatorID) -> SimulatorWorker {
        if let worker = workers[deviceID.rawValue] {
            return worker
        }
        let worker = SimulatorWorker(deviceID: deviceID)
        workers[deviceID.rawValue] = worker
        return worker
    }

    private func validate(_ deviceID: SimulatorID) throws {
        guard !deviceID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimUseError.invalidRequest("Device ID must not be empty.")
        }
    }

    private func validate(_ events: [HIDEvent]) throws {
        for event in events {
            switch event {
            case let .touchDown(x, y), let .touchMove(x, y), let .touchUp(x, y), let .tap(x, y):
                try validateCoordinate(x, y)
            case let .swipe(startX, startY, endX, endY, delta, duration):
                try validateCoordinate(startX, startY)
                try validateCoordinate(endX, endY)
                guard delta.isFinite, delta > 0, duration.isFinite, duration > 0 else {
                    throw SimUseError.invalidRequest("Swipe delta and duration must be finite positive values.")
                }
            case let .keyDown(keyCode), let .keyUp(keyCode):
                guard keyCode <= 255 else {
                    throw SimUseError.invalidRequest("HID keycode must be between 0 and 255.")
                }
            case let .buttonDown(button), let .buttonUp(button):
                guard (1...5).contains(button) else {
                    throw SimUseError.invalidRequest("HID button must be between 1 and 5.")
                }
            case let .delay(seconds):
                guard seconds.isFinite, seconds >= 0 else {
                    throw SimUseError.invalidRequest("HID delay must be a finite non-negative value.")
                }
            case .applePay:
                throw SimUseError.backend(
                    "Apple Pay simulator input is unavailable in this release.",
                    hint: "Use a supported simulator hardware action instead."
                )
            case .shake, .sideButton, .siri:
                break
            }
        }
    }

    private func validateCoordinate(_ x: Double, _ y: Double) throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw SimUseError.invalidRequest("HID coordinates must be finite non-negative values.")
        }
    }
}

public final class SimulatorSession: @unchecked Sendable {
    public let deviceID: SimulatorID
    private let worker: SimulatorWorker

    fileprivate init(deviceID: SimulatorID, worker: SimulatorWorker) {
        self.deviceID = deviceID
        self.worker = worker
    }

    public func send(_ events: [HIDEvent]) async throws {
        try await worker.send(events)
    }

    public func sendTimed(_ events: [HIDEvent]) async throws -> [HIDEventTiming] {
        try await worker.sendTimed(events)
    }

    public func invalidate() async {
        await worker.invalidate()
    }
}

/// Preserves the order of independently submitted HID event batches.
///
/// `SimulatorWorker` is main-actor isolated but yields while a private
/// framework call is in flight. Without this gate, separately submitted
/// touch-down, touch-move, and touch-up batches can overlap at those yield
/// points and reach the simulator out of order.
actor HIDEventSendCoordinator {
    private var tail: Task<Void, Never>?

    func acquire() async -> HIDEventSendTurn {
        let predecessor = tail
        let turn = HIDEventSendTurn()
        tail = Task.detached {
            _ = await predecessor?.value
            await turn.waitForCompletion()
        }
        _ = await predecessor?.value
        return turn
    }
}

actor HIDEventSendTurn {
    private var isCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForCompletion() async {
        guard isCompleted == false else { return }
        await withCheckedContinuation { continuation in
            if isCompleted {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard isCompleted == false else { return }
        isCompleted = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

/// Owns all mutable state associated with one simulator. A separate worker
/// is created for every UDID, so operations for different simulators can
/// proceed concurrently while HID events for one simulator remain ordered.
@MainActor
private final class SimulatorWorker {
    private let deviceID: SimulatorID
    private var session: HIDInteractor.Session?
    private let livenessTracker = ProcessLivenessTracker()
    private let hidEventCoordinator = HIDEventSendCoordinator()

    init(deviceID: SimulatorID) {
        self.deviceID = deviceID
    }

    func open() async throws {
        if session == nil {
            // Match every CLI HID verb: merely creating the HID transport
            // does not load all private framework layers required for
            // reliable pointer delivery. Keyboard events can appear to
            // work without this, while touch events may be delivered to a
            // stale surface.
            let logger = SimUseLogger()
            try await performEssentialSetup(logger: logger)
            try await performGlobalSetup(logger: logger)
            session = try await HIDInteractor.makeSession(
                for: deviceID.rawValue,
                logger: logger
            )
        }
    }

    func send(_ events: [HIDEvent]) async throws {
        _ = try await sendTimed(events)
    }

    func sendTimed(_ events: [HIDEvent]) async throws -> [HIDEventTiming] {
        guard !events.isEmpty else { return [] }
        try validate(events)

        let turn = await hidEventCoordinator.acquire()
        do {
            let timings = try await performSendTimed(events)
            await turn.complete()
            return timings
        } catch {
            await turn.complete()
            session = nil
            throw error
        }
    }

    private func performSendTimed(_ events: [HIDEvent]) async throws -> [HIDEventTiming] {
        if session == nil {
            try await open()
        }
        guard let session else {
            throw SimUseError.transient("Simulator HID session was not initialized.")
        }
        let logger = SimUseLogger()
        let start = Date.timeIntervalSinceReferenceDate
        var previous = start
        var timings: [HIDEventTiming] = []
        timings.reserveCapacity(events.count)
        for (index, event) in events.enumerated() {
            if case .shake = event {
                try SimulatorShake.perform(in: session)
            } else if case let .tap(x, y) = event {
                // `tapAt` is accepted by the Device Hub transport but
                // can be dropped before UIKit observes it. Mirror the
                // CLI path and send the complete press lifecycle as one
                // composite event; DTUHID drains at the gesture boundary.
                try await HIDInteractor.performHIDEvent(
                    FBSimulatorHIDEvent.composite([
                        .touch(direction: .down, x: x, y: y),
                        .touch(direction: .up, x: x, y: y),
                    ]),
                    in: session,
                    logger: logger
                )
            } else if let backendEvent = event.makeBackendEvent() {
                // Device Hub's DTUHID transport only drains a digitizer
                // event at a composite boundary. Keep every public
                // `sendTimed` call discrete so clients can stream a real
                // down → move… → up sequence, while making each
                // individual touch event observable by the simulator.
                let transportEvent = event.requiresStandaloneFlush
                    ? FBSimulatorHIDEvent.composite([backendEvent])
                    : backendEvent
                try await HIDInteractor.performHIDEvent(
                    transportEvent,
                    in: session,
                    logger: logger,
                    stabilizationDelayMilliseconds: event.continuousTouchStabilizationDelayMilliseconds
                )
            }
            let now = Date.timeIntervalSinceReferenceDate
            timings.append(HIDEventTiming(index: index, event: event, interval: now - previous, elapsed: now - start))
            previous = now
        }
        return timings
    }

    func invalidate() {
        session = nil
        HIDInteractor.clearHIDConnection(for: deviceID.rawValue)
    }

    func resetLiveness(to snapshot: AppSnapshot, now: Date) {
        livenessTracker.reset(to: snapshot, now: now)
    }

    private func validate(_ events: [HIDEvent]) throws {
        for event in events {
            switch event {
            case let .touchDown(x, y), let .touchMove(x, y), let .touchUp(x, y), let .tap(x, y):
                try validateCoordinate(x, y)
            case let .swipe(startX, startY, endX, endY, delta, duration):
                try validateCoordinate(startX, startY)
                try validateCoordinate(endX, endY)
                guard delta.isFinite, delta > 0, duration.isFinite, duration > 0 else {
                    throw SimUseError.invalidRequest("Swipe delta and duration must be finite positive values.")
                }
            case let .keyDown(keyCode), let .keyUp(keyCode):
                guard keyCode <= 255 else { throw SimUseError.invalidRequest("HID keycode must be between 0 and 255.") }
            case let .buttonDown(button), let .buttonUp(button):
                guard (1...5).contains(button) else { throw SimUseError.invalidRequest("HID button must be between 1 and 5.") }
            case let .delay(seconds):
                guard seconds.isFinite, seconds >= 0 else { throw SimUseError.invalidRequest("HID delay must be a finite non-negative value.") }
            case .applePay:
                throw SimUseError.backend(
                    "Apple Pay simulator input is unavailable in this release.",
                    hint: "Use a supported simulator hardware action instead."
                )
            case .shake, .sideButton, .siri:
                break
            }
        }
    }

    private func validateCoordinate(_ x: Double, _ y: Double) throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw SimUseError.invalidRequest("HID coordinates must be finite non-negative values.")
        }
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

public protocol SimUseRequest: Sendable {
    associatedtype Output: Sendable

    func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> Output
}

/// Application-facing HID events. The underlying idb event type stays inside
/// the adapter target.
public enum HIDEvent: Sendable {
    /// Sends the Simulator.app-native Device > Shake operation.
    case shake
    /// Sends a short Apple Pay button press to the selected iOS Simulator.
    @available(*, deprecated, message: "Apple Pay simulator input is unavailable in this release; support is planned for a future release.")
    case applePay
    /// Sends a short side-button press to the selected iOS Simulator.
    @available(*, deprecated, message: "Side Button simulator input is unavailable in this release; support is planned for a future release.")
    case sideButton
    /// Sends a short Siri button press to the selected iOS Simulator.
    @available(*, deprecated, message: "Siri simulator input is unavailable in this release; support is planned for a future release.")
    case siri
    case touchDown(x: Double, y: Double)
    /// idb's fixed revision represents a move in a continuous touch path
    /// with another `touchDownAt` event on the same HID connection.
    case touchMove(x: Double, y: Double)
    case touchUp(x: Double, y: Double)
    case tap(x: Double, y: Double)
    case swipe(startX: Double, startY: Double, endX: Double, endY: Double, delta: Double, duration: Double)
    case keyDown(UInt32)
    case keyUp(UInt32)
    case buttonDown(UInt32)
    case buttonUp(UInt32)
    case delay(TimeInterval)

    fileprivate func makeBackendEvent() -> FBSimulatorHIDEvent? {
        switch self {
        case .shake:
            return nil
        case .applePay:
            return FBSimulatorHIDEvent.shortButtonPress(FBSimulatorHIDButton(rawValue: 1)!)
        case .sideButton:
            return FBSimulatorHIDEvent.shortButtonPress(FBSimulatorHIDButton(rawValue: 4)!)
        case .siri:
            return FBSimulatorHIDEvent.shortButtonPress(FBSimulatorHIDButton(rawValue: 5)!)
        case let .touchDown(x, y):
            return .touch(direction: .down, x: x, y: y)
        case let .touchMove(x, y):
            return .touch(direction: .down, x: x, y: y)
        case let .touchUp(x, y):
            return .touch(direction: .up, x: x, y: y)
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
            return .keyboard(direction: .down, keyCode: keyCode)
        case let .keyUp(keyCode):
            return .keyboard(direction: .up, keyCode: keyCode)
        case let .buttonDown(button):
            return .button(direction: .down, button: FBSimulatorHIDButton(rawValue: Int32(button))!)
        case let .buttonUp(button):
            return .button(direction: .up, button: FBSimulatorHIDButton(rawValue: Int32(button))!)
        case let .delay(seconds):
            return FBSimulatorHIDEvent.delay(seconds)
        }
    }

    /// Continuous touch clients submit one primitive at a time. DTUHID needs
    /// each primitive wrapped in a composite to flush it, but the wrapper
    /// must not coalesce primitives or change their ordering.
    var requiresStandaloneFlush: Bool {
        switch self {
        case .touchDown, .touchMove, .touchUp:
            true
        case .shake, .applePay, .sideButton, .siri, .tap, .swipe,
             .keyDown, .keyUp, .buttonDown, .buttonUp, .delay:
            false
        }
    }

    /// Continuous preview input must keep up with pointer updates. Eight
    /// milliseconds remains above the minimum interval required by the
    /// underlying Indigo transport, while the final touch-up retains the
    /// normal drain delay so it is not dropped when the stream goes idle.
    var continuousTouchStabilizationDelayMilliseconds: UInt64? {
        switch self {
        case .touchDown, .touchMove:
            8
        case .shake, .applePay, .sideButton, .siri, .touchUp, .tap, .swipe,
             .keyDown, .keyUp, .buttonDown, .buttonUp, .delay:
            nil
        }
    }
}

/// Timing for one event in a serialized HID sequence.
public struct HIDEventTiming: Sendable {
    public let index: Int
    public let event: HIDEvent
    public let interval: TimeInterval
    public let elapsed: TimeInterval

    public init(index: Int, event: HIDEvent, interval: TimeInterval, elapsed: TimeInterval) {
        self.index = index
        self.event = event
        self.interval = interval
        self.elapsed = elapsed
    }
}
