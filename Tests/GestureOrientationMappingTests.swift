// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Directional gesture presets (`scroll-*`, `swipe-from-*-edge`) name a
// VISUAL direction, but the HID layer consumes device-native portrait
// coordinates — so on a rotated device an untransformed preset points
// 90°/180° away from what its name promises (issue #66; scroll-up on a
// landscape iPad scrolled nothing while a native-horizontal swipe
// scrolled the list vertically).
//
// `GestureOrientationMapping` is the pure decision layer for the fix:
// resolve the visual screen size the preset math runs in (explicit
// flags win, else the calibrated UI size, else the legacy 390x844),
// then carry each UI-space stroke endpoint across `uiToFramebuffer`.
// The underlying per-orientation formulas are pinned by
// DisplayOrientationTests; these tests pin the preset→HID composition.

private let iPadNative = NativePortraitSize(width: 1032, height: 1376)

private func calibration(_ orientation: DisplayOrientation, native: NativePortraitSize? = iPadNative) -> OrientationCalibration {
    OrientationCalibration(orientation: orientation, native: native, probesUsed: 0, advisory: nil)
}

@Suite("GestureOrientationMapping.visualSize")
struct GestureVisualSizeTests {

    @Test("Explicit flags win over the calibrated size")
    func explicitFlagsWin() {
        let size = GestureOrientationMapping.visualSize(
            explicitWidth: 800, explicitHeight: 600,
            calibration: calibration(.landscapeRight))
        #expect(size.width == 800 && size.height == 600)
    }

    @Test("A partially explicit size fills the other axis from the calibrated UI size")
    func partialExplicitFillsFromUISize() {
        let size = GestureOrientationMapping.visualSize(
            explicitWidth: 800, explicitHeight: nil,
            calibration: calibration(.landscapeRight))
        #expect(size.width == 800 && size.height == 1032)
    }

    @Test("Portrait default is the native size")
    func portraitDefaultIsNative() {
        let size = GestureOrientationMapping.visualSize(
            explicitWidth: nil, explicitHeight: nil,
            calibration: calibration(.portrait))
        #expect(size.width == 1032 && size.height == 1376)
    }

    @Test("Landscape default swaps the native dimensions")
    func landscapeDefaultSwaps() {
        let size = GestureOrientationMapping.visualSize(
            explicitWidth: nil, explicitHeight: nil,
            calibration: calibration(.landscapeRight))
        #expect(size.width == 1376 && size.height == 1032)
    }

    @Test("Without a native size the legacy 390x844 default survives")
    func noNativeFallsBackToLegacy() {
        let size = GestureOrientationMapping.visualSize(
            explicitWidth: nil, explicitHeight: nil,
            calibration: calibration(.portrait, native: nil))
        #expect(size.width == 390 && size.height == 844)
    }
}

@Suite("GestureOrientationMapping.hidStroke")
struct GestureHIDStrokeTests {

    /// Runs the full preset pipeline the way the command does: preset
    /// math in the calibrated visual size, then endpoint mapping.
    private func hidEndpoints(
        _ preset: GesturePreset,
        _ orientation: DisplayOrientation
    ) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let cal = calibration(orientation)
        let visual = GestureOrientationMapping.visualSize(
            explicitWidth: nil, explicitHeight: nil, calibration: cal)
        let stroke = preset.strokes(screenWidth: visual.width, screenHeight: visual.height)[0]
        return GestureOrientationMapping.hidStroke(stroke, calibration: cal)
    }

    private func expect(
        _ got: (startX: Double, startY: Double, endX: Double, endY: Double),
        _ want: (Double, Double, Double, Double),
        _ label: String
    ) {
        #expect(got.startX == want.0 && got.startY == want.1
            && got.endX == want.2 && got.endY == want.3,
            "\(label): got (\(got.startX),\(got.startY))→(\(got.endX),\(got.endY)), want (\(want.0),\(want.1))→(\(want.2),\(want.3))")
    }

    @Test("Portrait strokes pass through unchanged")
    func portraitIsIdentity() {
        expect(hidEndpoints(.scrollUp, .portrait), (516, 860, 516, 516), "scroll-up")
        expect(hidEndpoints(.scrollDown, .portrait), (516, 516, 516, 860), "scroll-down")
        expect(hidEndpoints(.scrollLeft, .portrait), (645, 688, 387, 688), "scroll-left")
        expect(hidEndpoints(.scrollRight, .portrait), (387, 688, 645, 688), "scroll-right")
    }

    @Test("Landscape-right scrolls emit along the native-horizontal axis")
    func landscapeRightScrolls() {
        // The issue #66 field case: visual-vertical scrolling must come
        // out as native-x motion (f = (W−uy, ux)).
        expect(hidEndpoints(.scrollUp, .landscapeRight), (387, 688, 645, 688), "scroll-up")
        expect(hidEndpoints(.scrollDown, .landscapeRight), (645, 688, 387, 688), "scroll-down")
        expect(hidEndpoints(.scrollLeft, .landscapeRight), (516, 860, 516, 516), "scroll-left")
        expect(hidEndpoints(.scrollRight, .landscapeRight), (516, 516, 516, 860), "scroll-right")
    }

    @Test("Landscape-left scrolls mirror landscape-right")
    func landscapeLeftScrolls() {
        // f = (uy, H−ux)
        expect(hidEndpoints(.scrollUp, .landscapeLeft), (645, 688, 387, 688), "scroll-up")
        expect(hidEndpoints(.scrollDown, .landscapeLeft), (387, 688, 645, 688), "scroll-down")
        expect(hidEndpoints(.scrollLeft, .landscapeLeft), (516, 516, 516, 860), "scroll-left")
        expect(hidEndpoints(.scrollRight, .landscapeLeft), (516, 860, 516, 516), "scroll-right")
    }

    @Test("Upside-down scrolls are the portrait strokes mirrored on both axes")
    func upsideDownScrolls() {
        // f = (W−ux, H−uy)
        expect(hidEndpoints(.scrollUp, .portraitUpsideDown), (516, 516, 516, 860), "scroll-up")
        expect(hidEndpoints(.scrollDown, .portraitUpsideDown), (516, 860, 516, 516), "scroll-down")
        expect(hidEndpoints(.scrollLeft, .portraitUpsideDown), (387, 688, 645, 688), "scroll-left")
        expect(hidEndpoints(.scrollRight, .portraitUpsideDown), (645, 688, 387, 688), "scroll-right")
    }

    @Test("Edge presets track the visual edges under landscape-right")
    func landscapeRightEdges() {
        // Visual left edge = native top edge under landscape-right, etc.
        expect(hidEndpoints(.swipeFromLeftEdge, .landscapeRight), (516, 20, 516, 1356), "left-edge")
        expect(hidEndpoints(.swipeFromRightEdge, .landscapeRight), (516, 1356, 516, 20), "right-edge")
        expect(hidEndpoints(.swipeFromTopEdge, .landscapeRight), (1012, 688, 20, 688), "top-edge")
        expect(hidEndpoints(.swipeFromBottomEdge, .landscapeRight), (20, 688, 1012, 688), "bottom-edge")
    }

    @Test("A calibration without a native size leaves strokes untouched")
    func noNativeIsIdentity() {
        let cal = calibration(.landscapeRight, native: nil)
        let stroke = GesturePreset.scrollUp.strokes(screenWidth: 390, screenHeight: 844)[0]
        let got = GestureOrientationMapping.hidStroke(stroke, calibration: cal)
        #expect(got.startX == stroke.startX && got.startY == stroke.startY
            && got.endX == stroke.endX && got.endY == stroke.endY)
    }
}
