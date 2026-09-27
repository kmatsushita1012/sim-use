// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import SimUseVideo

// The FB*-tied capture entry point for the shared frame utilities.
// Everything else in `VideoFrameUtilities` is platform-neutral and lives
// in SimUseVideo; this extension is the one piece that must stay inside
// iOSSimBackend's FB* dep cone.
extension VideoFrameUtilities {
    public static func captureScreenshotData(from simulator: FBSimulator) async throws -> Data {
        let data = try await simulator.takeScreenshot(format: .png)
        guard !data.isEmpty else {
            throw VideoProcessingError.emptyScreenshot
        }
        return data
    }
}
