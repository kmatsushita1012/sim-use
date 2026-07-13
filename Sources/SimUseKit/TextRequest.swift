// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Application-facing text input request.
///
/// This is deliberately separate from `IOSSimTypeCommand`: the latter is a
/// CLI/ArgumentParser command and its property wrappers must not be accessed
/// through direct initialization from an application target.
public struct TextRequest: SimUseRequest, Sendable {
    public typealias Output = EmptyCommandResult

    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> EmptyCommandResult {
        let events = try Self.makeEvents(from: text)
        try await client.send(events, on: deviceID)
        return EmptyCommandResult()
    }

    private static func makeEvents(from text: String) throws -> [HIDEvent] {
        var events: [HIDEvent] = []
        events.reserveCapacity(text.count * 2)

        for character in text {
            let keyEvent = KeyEvent.keyCodeForString(String(character))
            guard keyEvent.keyCode != 0 else {
                throw TextRequestError.unsupportedCharacter(character)
            }

            let keyCode = UInt32(keyEvent.keyCode)
            if keyEvent.shift {
                events.append(.keyDown(225))
                events.append(.keyDown(keyCode))
                events.append(.keyUp(keyCode))
                events.append(.keyUp(225))
            } else {
                events.append(.keyDown(keyCode))
                events.append(.keyUp(keyCode))
            }
        }

        return events
    }
}

public enum TextRequestError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedCharacter(Character)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedCharacter(character):
            return "No keycode found for character: '\(character)'"
        }
    }
}
