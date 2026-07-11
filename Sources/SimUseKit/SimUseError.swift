// SPDX-License-Identifier: Apache-2.0
import Foundation
import ArgumentParser
import SimUseCore

/// Errors exposed by the application-facing API.
public enum SimUseError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case deviceNotFound(String)
    case deviceNotBooted(String)
    case staleSession(deviceID: String, underlying: String)
    case transient(String)
    case backend(String, hint: String?)

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message), let .deviceNotFound(message),
             let .deviceNotBooted(message), let .transient(message):
            return message
        case let .staleSession(deviceID, underlying):
            return "Simulator session for \(deviceID) is no longer valid: \(underlying)"
        case let .backend(message, hint):
            if let hint { return "\(message)\nHint: \(hint)" }
            return message
        }
    }

    public static func map(_ error: Error, deviceID: String) -> SimUseError {
        if let error = error as? SimUseError { return error }
        let message = error.localizedDescription
        if error is ValidationError {
            return .invalidRequest(message)
        }
        if DaemonErrorKind.isStaleSimulatorMessage(message) {
            return .staleSession(deviceID: deviceID, underlying: message)
        }
        if DaemonErrorKind.classify(error) == .transientBooting {
            return .transient(message)
        }
        if message.localizedCaseInsensitiveContains("not booted") {
            return .deviceNotBooted(message)
        }
        if message.localizedCaseInsensitiveContains("not found") {
            return .deviceNotFound(message)
        }
        if let hint = (error as? HintProviding)?.hint {
            return .backend(message, hint: hint)
        }
        return .backend(message, hint: nil)
    }
}
