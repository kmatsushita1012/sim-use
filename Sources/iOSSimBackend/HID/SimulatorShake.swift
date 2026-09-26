// SPDX-License-Identifier: Apache-2.0
import Foundation
import ObjectiveC
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// Sends the same native shake signal that Simulator.app's Device > Shake
/// action sends to an iOS Simulator.
///
/// The local idb revision predates its public `FBSimulatorHIDEvent.shake`
/// wrapper, so the SimDevice method is invoked through the Objective-C runtime
/// after FBSimulatorControl has loaded CoreSimulator. The notification is
/// device-scoped and does not depend on Simulator.app focus or accessibility
/// automation.
public enum SimulatorShake {
    public static let darwinNotification = "com.apple.UIKit.SimulatorShake"

    public static func perform(in session: HIDInteractor.Session) throws {
        let productFamily = session.simulator.productFamily.rawValue
        guard productFamily == 1 || productFamily == 2 else {
            throw CLIError(errorDescription:
                "Native Simulator Shake is supported only on iPhone and iPad Simulator devices."
            )
        }

        guard let device = session.simulator.value(forKey: "device") as AnyObject? else {
            throw CLIError(errorDescription: "The selected Simulator does not expose its CoreSimulator device.")
        }
        let selector = NSSelectorFromString("postDarwinNotification:error:")

        guard let method = class_getInstanceMethod(object_getClass(device), selector) else {
            throw CLIError(errorDescription:
                "The selected Simulator runtime does not expose native Shake support."
            )
        }

        typealias PostDarwinNotification = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            UnsafeMutablePointer<NSError?>?
        ) -> Bool

        let implementation = method_getImplementation(method)
        let post = unsafeBitCast(implementation, to: PostDarwinNotification.self)
        var underlyingError: NSError?
        let didPost = post(device, selector, darwinNotification as NSString, &underlyingError)

        guard didPost else {
            let detail = underlyingError?.localizedDescription ?? "Unknown CoreSimulator error."
            throw CLIError(errorDescription: "Failed to send native Simulator Shake: \(detail)")
        }
    }
}
