// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A verb the tool implements is not available on the resolved target.
///
/// Thrown from a top-level verb's platform switch when the target's
/// channel cannot carry the operation (e.g. the physical-iOS
/// accessibility audit channel exposes no coordinate input), replacing
/// the pre-routing blanket rejection with a per-verb decision. Modelled
/// on `HIDKeyCommandHelp.androidUnsupportedMessage`: the message states
/// *why* the verb cannot work on this target, and the hint carries the
/// nearest equivalent so an agent can re-plan instead of retrying.
///
/// This is a capability statement about the target, not a usage error:
/// the invocation was well-formed and would succeed against a
/// simulator, so it surfaces through the runtime error path (`--json`
/// envelope with `hint`, exit 1), not ArgumentParser's usage exit.
public struct TargetCapabilityError: LocalizedError, HintProviding {
    /// The verb as the user typed it (e.g. "swipe", "record-video").
    public let verb: String
    /// Human name of the target class (e.g. "physical iOS devices").
    public let target: String
    /// Why the target's channel cannot carry this operation.
    public let reason: String
    /// The nearest equivalent on this target, or guidance when there
    /// is none yet. Rides the `hint` channel.
    public let alternative: String?

    public init(verb: String, target: String, reason: String, alternative: String?) {
        self.verb = verb
        self.target = target
        self.reason = reason
        self.alternative = alternative
    }

    public var errorDescription: String? {
        "`\(verb)` is not supported on \(target): \(reason)"
    }

    public var hint: String? { alternative }

    /// The physical-iOS capability boundary, shared by every top-level
    /// verb's `.iOSDevice` arm so the target name stays uniform.
    public static func physicalIOS(verb: String, reason: String, alternative: String?) -> TargetCapabilityError {
        TargetCapabilityError(
            verb: verb,
            target: "physical iOS devices",
            reason: reason,
            alternative: alternative
        )
    }
}
