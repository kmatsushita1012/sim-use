// SPDX-License-Identifier: Apache-2.0
import Foundation
import AndroidBackend
import SimUseCore
import iOSSimBackend

/// Cross-platform long-press adapter for the top-level `long-press` verb.
/// The target is expressed as a reusable `TapRequest`; only the hold
/// duration changes. This preserves the complete alias/selector/frame input
/// surface without exposing the executable target's private `LongPress` type.
public struct LongPressRequest: SimUseRequest {
    public typealias Output = TapResult
    public let target: TapRequest
    public let duration: Double

    public init(target: TapRequest, duration: Double = 0.8) {
        self.target = target
        self.duration = duration
    }

    @MainActor
    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> TapResult {
        guard duration.isFinite, duration > 0, duration <= 10 else {
            throw SimUseError.invalidRequest("Long-press duration must be greater than 0 and at most 10 seconds.")
        }

        switch PlatformRouter.resolve(udid: deviceID.rawValue) {
        case .android:
            let explicit = try TapCoordinateResolver.resolve(
                x: target.x,
                y: target.y,
                point: target.point
            )
            let frame = target.frameSpecs.isEmpty
                ? nil
                : try SelectorFrameFilter(specs: target.frameSpecs)
            let selector = AndroidSelector(
                id: target.accessibilityIdentifier,
                label: target.label,
                labelContains: target.labelContains,
                labelRegex: target.labelRegex,
                value: target.value,
                elementType: target.elementType,
                frame: frame
            )
            let result = try AndroidTapCommand.performTap(
                udid: deviceID.rawValue,
                alias: target.alias,
                x: explicit.map { Int($0.x.rounded()) },
                y: explicit.map { Int($0.y.rounded()) },
                selector: selector,
                duration: duration,
                multiTouch: nil
            )
            return TapResult(x: Double(result.x), y: Double(result.y))
        case .iOSSim, .none:
            let request = TapRequest(
                alias: target.alias,
                point: target.point,
                x: target.x,
                y: target.y,
                accessibilityIdentifier: target.accessibilityIdentifier,
                label: target.label,
                value: target.value,
                labelContains: target.labelContains,
                labelRegex: target.labelRegex,
                elementType: target.elementType,
                frameSpecs: target.frameSpecs,
                preDelay: target.preDelay,
                postDelay: target.postDelay,
                duration: duration,
                waitTimeout: target.waitTimeout,
                pollInterval: target.pollInterval
            )
            return try await request.execute(on: deviceID, using: client)
        }
    }
}

public struct AppStateRequest: SimUseRequest {
    public typealias Output = AppStateResult
    public let bundleID: String?
    public let reset: Bool

    public init(bundleID: String? = nil, reset: Bool = false) {
        self.bundleID = bundleID
        self.reset = reset
    }

    @MainActor
    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> AppStateResult {
        let snapshot: AppSnapshot?
        let platform: String
        if PlatformRouter.looksLikeAndroid(deviceID.rawValue) {
            platform = "android"
            snapshot = AndroidProcessLister.appSnapshot(serial: deviceID.rawValue)
        } else {
            platform = "ios"
            snapshot = BundleIdentifierResolver.appSnapshot(udid: deviceID.rawValue)
        }
        guard let snapshot else {
            throw SimUseError.transient("Could not read the running-process list from \(deviceID.rawValue).")
        }

        let tracker = client.livenessTracker(for: deviceID)
        if reset {
            tracker.reset(to: snapshot, now: Date())
        }

        let apps = snapshot.appsByPid
            .map { AppProcess(bundleID: $0.value, pid: $0.key) }
            .sorted { $0.bundleID < $1.bundleID }
        let query = bundleID.map { id in
            AppStateQuery(
                bundleID: id,
                state: snapshot.liveness(ofBundleId: id) == .dead ? .notRunning : .running
            )
        }
        return AppStateResult(platform: platform, apps: apps, query: query, didReset: reset)
    }
}

public struct AppProcess: Codable, Equatable, Sendable {
    public let bundleID: String
    public let pid: Int

    public init(bundleID: String, pid: Int) {
        self.bundleID = bundleID
        self.pid = pid
    }
}

public struct AppStateQuery: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running
        case notRunning = "not_running"
    }

    public let bundleID: String
    public let state: State

    public init(bundleID: String, state: State) {
        self.bundleID = bundleID
        self.state = state
    }
}

public struct AppStateResult: Codable, Equatable, Sendable {
    public let platform: String
    public let apps: [AppProcess]
    public let query: AppStateQuery?
    public let didReset: Bool

    public init(platform: String, apps: [AppProcess], query: AppStateQuery?, didReset: Bool) {
        self.platform = platform
        self.apps = apps
        self.query = query
        self.didReset = didReset
    }
}
