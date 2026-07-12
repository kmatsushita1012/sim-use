// SPDX-License-Identifier: Apache-2.0
import Foundation
import AndroidBackend
import FBSimulatorControl
import SimUseCore
import iOSSimBackend

public struct ScreenshotRequest: SimUseRequest {
    public typealias Output = ScreenshotResult

    public init() {}

    @MainActor
    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> ScreenshotResult {
        if PlatformRouter.looksLikeAndroid(deviceID.rawValue) {
            return ScreenshotResult(data: try AndroidScreenshotCommand.performScreenshot(udid: deviceID.rawValue))
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
