// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Coordinate space for explicit gesture coordinates (issue #66).
///
/// `native` — device-native portrait framebuffer points: the HID
/// layer's own space and the historical contract for explicit
/// coordinates (issue #34 acceptance criterion). Zero-cost: no AX
/// round-trip, no calibration.
///
/// `ui` — visual space, the space every frame printed by `describe-ui`
/// uses. Endpoints are transformed through a per-command orientation
/// calibration before dispatch, so coordinates lifted from the outline
/// stay correct when the device is rotated.
public enum CoordinateSpace: String, CaseIterable, ExpressibleByArgument, Sendable {
    case native
    case ui
}
