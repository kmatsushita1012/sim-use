// SPDX-License-Identifier: Apache-2.0
import Foundation
import AndroidBackend
@preconcurrency import FBControlCore
import FBSimulatorControl
import SimUseCore
import SimUseVideo
import iOSSimBackend

public struct ScreenshotRequest: SimUseRequest {
    public typealias Output = ScreenshotResult

    public init() {}

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> ScreenshotResult {
        switch PlatformRouter.resolve(udid: deviceID.rawValue) {
        case .android:
            return ScreenshotResult(data: try AndroidScreenshotCommand.performScreenshot(udid: deviceID.rawValue))
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "ScreenshotRequest",
                reason: "this in-memory result API currently covers simulator and Android captures only.",
                alternative: "Use the top-level `sim-use screenshot --device <physical-udid>` command for a physical iOS capture."
            )
        case .iOSSim, .none:
            break
        }

        let logger = SimUseLogger()
        try await performGlobalSetup(logger: logger)
        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == deviceID.rawValue }) else {
            throw SimUseError.deviceNotFound("Simulator \(deviceID.rawValue) was not found.")
        }
        guard simulator.state == .booted else {
            throw SimUseError.deviceNotBooted("Simulator \(deviceID.rawValue) is not booted.")
        }
        return ScreenshotResult(data: try await VideoFrameUtilities.captureScreenshotData(from: simulator))
    }
}

public struct ScreenshotResult: Sendable, Equatable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}
