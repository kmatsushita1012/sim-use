// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - Error Types

/// Carries a human-readable error message that should reach the user
/// verbatim. Conforms to `LocalizedError` so `error.localizedDescription`
/// returns this message instead of Foundation's NSError bridge default
/// (`"The operation couldn't be completed. (CLIError error 1.)"`).
///
/// `errorDescription` is declared as `String?` (not `String`) so the
/// LocalizedError protocol witness is properly installed — Foundation's
/// bridging machinery only routes `localizedDescription` through the
/// LocalizedError implementation when the witness signature matches the
/// protocol exactly. Internal call sites pass non-optional strings; the
/// implicit Optional promotion keeps every existing callsite unchanged.
/// (LINEIOS-216942: required so daemon-side `DaemonErrorKind.classify`
/// can actually pattern-match the message and detect stale simulators.)
public struct CLIError: LocalizedError {
    public let errorDescription: String?

    public init(errorDescription: String) {
        self.errorDescription = errorDescription
    }
}

/// The target identifier names a physical iPhone or iPad, passed to a
/// surface that is simulator-only by contract (`sim-use ios <verb>`).
/// Thrown during device resolution (`DeviceOptions.resolve()` without
/// `allowPhysical`) so the caller fails fast with a pointer to the
/// routed top-level surface, instead of the shape heuristics misreading
/// the modern 8-16-hex device UDID as an unreachable Android serial.
/// The top-level cross-platform verbs no longer throw this: they route
/// physical UDIDs through `PlatformRouter` and decide per verb
/// (`TargetCapabilityError` when the capability is missing).
public struct PhysicalIOSDeviceError: LocalizedError, HintProviding {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public var errorDescription: String? {
        "\(identifier) is a physical iOS device; this command only drives iOS Simulators."
    }

    public var hint: String? {
        "Use the top-level verbs, which route physical iOS devices automatically: 'sim-use ui', 'sim-use tap '#<id>' / --label', and 'sim-use screenshot' (experimental; other verbs are not available on this channel). The 'sim-use ios-device' namespace also works, and additionally accepts ECIDs."
    }
}