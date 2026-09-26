// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Shared `--device` flag declaration plus resolution rule, lifted out
/// of the per-verb structs so all device-scoped commands stay in
/// lockstep on flag name, help text, and auto-resolution semantics.
///
/// Adopt with `@OptionGroup public var device: DeviceOptions` on every
/// command that takes a target simulator / device. Call
/// `try device.resolve()` from the conforming command's
/// `resolveDeferredArguments()`; read `device.resolved` thereafter (it
/// is the empty string until `resolve()` has run).
///
/// `--udid` is accepted as a deprecated alias for `--device`. Passing
/// both flags in one invocation is a fast-fail (a `ValidationError`
/// surfaced through ArgumentParser's normal exit path).
///
/// Resolution rule mirrors what every cross-platform forwarder did
/// pre-extraction: an explicit Android-shape identifier bypasses the
/// iOS-only `DeviceResolver` (which would otherwise probe `simctl` /
/// daemon footprints) and is kept verbatim. Everything else flows
/// through `DeviceResolver.resolve(explicit:)`.
///
/// Android-only verbs (`sim-use android <verb>`) use
/// `AndroidDeviceOptions` instead — same flag surface but the resolver
/// refuses to auto-pick a booted iOS simulator there, since that would
/// produce a confusing "simulator not booted" failure deep in the
/// wrong backend.
public struct DeviceOptions: ParsableArguments {
    @Option(
        name: .customLong("device"),
        help: "Target device — iOS Simulator UDID or Android adb serial. Auto-detected by string shape. Optional — defaults to the only booted iOS simulator on the host (or to the SIM_USE_DEVICE / SIM_USE_UDID env var when set)."
    )
    public var device: String?

    @Option(
        name: .customLong("udid"),
        help: ArgumentHelp(
            "Deprecated alias for --device. Still accepted; may be removed in a future release.",
            visibility: .default
        )
    )
    public var udid: String?

    /// Resolved device identifier. Populated by `resolve()`; the empty
    /// string until then. Reading this before resolution is a
    /// programmer error in a command's `execute()` body and we accept
    /// the runtime breakage rather than fronting it with an Optional
    /// that would force every call-site to unwrap.
    public var resolved: String = ""

    /// Keep ArgumentParser's property wrappers in their initial state.
    /// Explicitly assigning `@Option`-backed fields here marks them as
    /// already parsed, then ArgumentParser traps while constructing a
    /// command from CLI arguments.
    public init() {}

    public init(device: String?, udid: String? = nil, resolved: String = "") {
        self.device = device
        self.udid = udid
        self.resolved = resolved
    }

    /// `allowPhysical` marks the caller as physical-iOS-aware: the 14
    /// top-level cross-platform verbs pass `true` and route (or reject
    /// per-verb via `TargetCapabilityError`) in their platform switch.
    /// The `sim-use ios <verb>` namespace keeps the default `false` —
    /// it is simulator-only by contract, so a physical UDID still
    /// fast-fails here with a pointer to the routed surface instead of
    /// surfacing as a confusing "simulator not found" deep in
    /// FBSimulatorControl.
    public mutating func resolve(allowPhysical: Bool = false) throws {
        let explicit = try Self.selectExplicit(device: device, udid: udid)
        if let arg = explicit, PlatformRouter.looksLikeAndroid(arg) {
            resolved = arg
            return
        }
        let candidate = try DeviceResolver.resolve(explicit: explicit)
        // Checked on the resolved value, not just the explicit flag, so a
        // physical UDID arriving via SIM_USE_DEVICE / SIM_USE_UDID is
        // treated identically.
        guard allowPhysical || !PlatformRouter.looksLikePhysicalIOSDevice(candidate) else {
            throw PhysicalIOSDeviceError(identifier: candidate)
        }
        resolved = candidate
    }

    /// Apply the same `--device` / `--udid` mutual-exclusion rule used
    /// by `DeviceOptions.resolve()` to a pair of raw values. Exposed so
    /// `AndroidDeviceOptions` (and any future variant) reuses the
    /// trim-and-pick-one semantics without re-implementing them.
    ///
    /// Conflicts surface as `CLIError` rather than ArgumentParser's
    /// `ValidationError`. `ValidationError` is only marshalled cleanly
    /// when thrown from inside `validate()`; thrown from
    /// `resolveDeferredArguments()` (where every other deferred
    /// `--device` rule lives) it is wrapped as
    /// `"The operation couldn't be completed. (ArgumentParser.ValidationError error 1.)"`,
    /// hiding the actual diagnostic from both stderr and the
    /// `--json` envelope.
    public static func selectExplicit(
        device: String?,
        udid: String?
    ) throws -> String? {
        let d = device?.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
        let u = udid?.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
        if d != nil && u != nil {
            throw CLIError(errorDescription: "Pass only one of --device / --udid (they are aliases).")
        }
        return d ?? u
    }
}

extension String {
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
