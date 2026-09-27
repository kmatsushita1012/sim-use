// SPDX-License-Identifier: Apache-2.0
import FBControlCore
import FBDeviceControl
import Foundation
import SimUseCore

public enum DeviceSessionError: Error, LocalizedError, CustomStringConvertible, HintProviding {
    case noDevices
    case selectionRequired(available: [String])
    case deviceNotFound(identifier: String, available: [String])
    case serviceUnavailable(underlying: Error)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .noDevices:
            return "no physical iOS devices are connected"
        case let .selectionRequired(available):
            return "multiple physical iOS devices are connected (\(available.joined(separator: ", ")))"
        case let .deviceNotFound(identifier, available):
            let known = available.isEmpty ? "none connected" : available.joined(separator: ", ")
            return "no physical iOS device with identifier \(identifier) (connected: \(known))"
        case let .serviceUnavailable(underlying):
            return "could not open the accessibility service on the device: \(underlying.localizedDescription)"
        }
    }

    // Recovery advice rides the shared `hint` channel — structurally in
    // the `--json` error envelope, as a `Hint:` line on the text path.
    public var hint: String? {
        switch self {
        case .noDevices:
            return "Connect the device over USB and make sure it is unlocked, paired and trusted; 'sim-use devices' shows every attached target."
        case .selectionRequired:
            return "Pass --device with the UDID or ECID of one of the listed devices."
        case .deviceNotFound:
            return "Run 'sim-use ios-device devices' to list attached devices. A freshly attached device may be listed by ECID until a session opens; either identifier is accepted."
        case .serviceUnavailable:
            return "Make sure the device is unlocked, trusts this Mac, and has Developer Mode enabled (Settings > Privacy & Security > Developer Mode)."
        }
    }
}

private struct DeviceOperationFailure: Error {
    let underlying: any Error
}

/// Tracks attachment identities until the set has stayed unchanged long
/// enough to include notifications delivered in the same discovery burst.
struct AttachmentQuiescence<Identity: Hashable> {
    let quietInterval: TimeInterval

    private var observed: Set<Identity> = []
    private var settleAfter: Date?

    init(quietInterval: TimeInterval) {
        self.quietInterval = quietInterval
    }

    mutating func observe(_ identities: Set<Identity>, at date: Date) -> Bool {
        if identities != observed {
            observed = identities
            settleAfter = identities.isEmpty ? nil : date.addingTimeInterval(quietInterval)
        }
        return !identities.isEmpty && settleAfter.map { date >= $0 } == true
    }
}

/// Drives one discovery pass: settle once the attachment set is quiet, but bail
/// early when nothing has attached within `emptyGrace`.
///
/// Without the grace, an empty set (nothing plugged in) never satisfies the
/// quiescence rule — it requires a non-empty, unchanged set — so discovery ran
/// the full timeout (~5 s) on every host with no device. The grace only applies
/// until the first device is seen; once `sawAny` latches, the full timeout is
/// back in force so a multi-device attach burst still coalesces.
struct AttachmentDiscovery<Identity: Hashable> {
    enum Step: Equatable {
        case keepWaiting
        case settled
        case bailEmpty
    }

    private var quiescence: AttachmentQuiescence<Identity>
    private let emptyGrace: TimeInterval
    private var sawAny = false
    private var start: Date?

    init(quietInterval: TimeInterval = 0.25, emptyGrace: TimeInterval) {
        quiescence = AttachmentQuiescence(quietInterval: quietInterval)
        self.emptyGrace = emptyGrace
    }

    mutating func step(_ identities: Set<Identity>, at now: Date) -> Step {
        let start = start ?? now
        self.start = start
        sawAny = sawAny || !identities.isEmpty
        if quiescence.observe(identities, at: now) { return .settled }
        if !sawAny, now.timeIntervalSince(start) >= emptyGrace { return .bailEmpty }
        return .keepWaiting
    }
}

/// Opens the accessibility audit daemon on a physical device and scopes it to
/// one piece of work.
///
/// sim-use installs and signs no runner: the service is reached over plain
/// usbmux lockdown without a Developer Disk Image. The target app must already
/// be development-signed (`get-task-allow=true`) and the device unlocked.
public enum DeviceSession {
    /// This service has no `.DVTSecureSocketProxy` variant — lockdown rejects
    /// that name as invalid. The base service still expects plaintext DTX after
    /// startup, so `DTXConnection` talks to the raw socket rather than sending
    /// frames back through the service connection's SSL context.
    static let serviceName = "com.apple.accessibility.axAuditDaemon.remoteserver"

    public struct DeviceSummary: Sendable {
        public let udid: String
        public let name: String
        public let osVersion: String
        public let state: String

        public init(udid: String, name: String, osVersion: String, state: String) {
            self.udid = udid
            self.name = name
            self.osVersion = osVersion
            self.state = state
        }

        /// The cross-platform `sim-use devices` row for this device.
        /// `udid` may be an ECID when AMDevice hasn't published the
        /// lockdown UDID yet (see `FBDevice.identity`) — surfaced as-is.
        public var unifiedDevice: Device {
            Device(
                udid: udid,
                name: name,
                platform: .ios,
                kind: .physical,
                state: state,
                runtime: osVersion
            )
        }
    }

    @MainActor
    public static func connectedDevices(logger: FBControlCoreLogger? = nil) async throws -> [DeviceSummary] {
        let set = try deviceSet(logger: logger)
        return attachedDevices(set).map(summary(of:))
    }

    /// Resolves a device the way `withClient` does — same discovery, same
    /// selection and error surface — without opening the audit service, for
    /// verbs that hand the actual work to another channel (e.g. `screenshot`
    /// via `devicectl`).
    @MainActor
    public static func resolveDevice(udid: String?, logger: FBControlCoreLogger? = nil) throws -> DeviceSummary {
        let set = try deviceSet(logger: logger)
        return summary(of: try resolve(udid, among: attachedDevices(set)))
    }

    @MainActor
    public static func withClient<Result>(
        udid: String?,
        connections poolSize: Int = 1,
        logger: FBControlCoreLogger? = nil,
        body: (AXAuditClient) async throws -> Result
    ) async throws -> Result {
        let set = try deviceSet(logger: logger)
        let device = try resolve(udid, among: attachedDevices(set))

        do {
            return try await withConnections(to: device, count: max(1, poolSize)) { dtx in
                let client = AXAuditClient(transport: PooledTransport(connections: dtx))
                try await client.prepare()
                // Not `defer`: the teardown has to complete while the
                // connections are still open, and a detached task would race
                // them shut.
                do {
                    let result = try await body(client)
                    await client.finish()
                    return result
                } catch {
                    await client.finish()
                    throw DeviceOperationFailure(underlying: error)
                }
            }
        } catch let failure as DeviceOperationFailure {
            // Command/runtime errors belong to the operation, not service
            // setup. Preserve their type and message so ArgumentParser emits a
            // normal exit-1 error instead of a misleading connection failure.
            throw failure.underlying
        } catch let error as DeviceSessionError {
            throw error
        } catch {
            throw DeviceSessionError.serviceUnavailable(underlying: error)
        }
    }

    /// Opens `count` service connections and tears them all down afterwards.
    /// Nesting the contexts keeps each one scoped without hand-rolled cleanup.
    @MainActor
    private static func withConnections<Result>(
        to device: FBDevice,
        count: Int,
        body: ([DTXConnection]) async throws -> Result
    ) async throws -> Result {
        var opened: [DTXConnection] = []

        func open(_ remaining: Int) async throws -> Result {
            guard remaining > 0 else { return try await body(opened) }
            return try await withFBFutureContext(device.startService(serviceName)) { connection in
                let dtx = try DTXConnection(connection: connection)
                defer { dtx.close() }
                try dtx.handshake()
                opened.append(dtx)
                return try await open(remaining - 1)
            }
        }
        return try await open(count)
    }

    /// AMDevice attachment is delivered through CFRunLoop sources on the thread
    /// that subscribed, and `FBDeviceSet` subscribes on the main queue. A CLI
    /// that never spins the main run loop therefore only ever sees the
    /// restorable-device half of a connected phone, and `startService:` then
    /// fails with "not AMDevice backed". Pumping the loop here is what lets the
    /// attachment land.
    @MainActor
    private static func attachedDevices(
        _ set: FBDeviceSet,
        timeout: TimeInterval = 5,
        emptyGrace: TimeInterval = 1
    ) -> [FBDevice] {
        let deadline = Date().addingTimeInterval(timeout)
        var attached: [FBDevice] = []
        var discovery = AttachmentDiscovery<ObjectIdentifier>(emptyGrace: emptyGrace)

        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)

            attached = set.allDevices.filter { $0.amDevice != nil }
            let identities = Set(attached.map { ObjectIdentifier($0) })
            switch discovery.step(identities, at: Date()) {
            case .settled: return attached
            case .bailEmpty: return []
            case .keepWaiting: break
            }
        }
        return attached.isEmpty ? set.allDevices : attached
    }

    private static func summary(of device: FBDevice) -> DeviceSummary {
        DeviceSummary(
            udid: device.identity,
            name: device.name,
            osVersion: device.osVersion.name.rawValue,
            state: FBiOSTargetStateStringFromState(device.state).rawValue
        )
    }

    /// AMDevice does not publish the lockdown UDID until a session is opened,
    /// so a connected device is identified by its ECID until then. Accept
    /// either, and default to the only device when there is just one.
    private static func resolve(_ identifier: String?, among devices: [FBDevice]) throws -> FBDevice {
        guard !devices.isEmpty else { throw DeviceSessionError.noDevices }
        let available = devices.map(\.identity)

        guard let identifier else {
            guard devices.count == 1, let only = devices.first else {
                throw DeviceSessionError.selectionRequired(available: available)
            }
            return only
        }
        guard let device = devices.first(where: { $0.udid == identifier || $0.uniqueIdentifier == identifier }) else {
            throw DeviceSessionError.deviceNotFound(identifier: identifier, available: available)
        }
        return device
    }

    @MainActor
    private static func deviceSet(logger: FBControlCoreLogger?) throws -> FBDeviceSet {
        try FBDeviceSet(
            logger: logger ?? FBControlCoreGlobalConfiguration.defaultLogger,
            delegate: nil,
            ecidFilter: nil
        )
    }
}

extension FBDevice {
    var identity: String { udid != "unknown" ? udid : uniqueIdentifier }
}
