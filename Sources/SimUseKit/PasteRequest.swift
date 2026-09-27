// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import iOSSimBackend

/// Application-facing paste request.
///
/// This request talks to the Simulator pasteboard and HID backend directly.
/// It does not construct an ArgumentParser command, launch `sim-use`, open a
/// daemon socket, or invoke an external simulator CLI.
public struct PasteRequest: SimUseRequest, Sendable {
    public typealias Output = EmptyCommandResult

    public let text: String
    public let replace: Bool

    public init(_ text: String, replace: Bool = false) {
        self.text = text
        self.replace = replace
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> EmptyCommandResult {
        guard !text.isEmpty else {
            throw SimUseError.invalidRequest("Paste text must not be empty.")
        }

        try await IOSSimulatorPasteboard.write(text: text, udid: deviceID.rawValue)
        var events: [HIDEvent] = []
        if replace {
            events += [.keyDown(227), .keyDown(4), .keyUp(4), .keyUp(227)]
        }
        events += [.keyDown(227), .keyDown(25), .keyUp(25), .keyUp(227)]
        try await client.send(events, on: deviceID)

        return EmptyCommandResult()
    }
}
