// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// Pins the `--point` fast-path decision rule: a single identity hit-test
// may settle the orientation only when exactly one candidate maps the
// probe point into the returned frame. The pre-fix rule gave portrait
// the tie, so on a rotated device a raw hit landing on a large frame
// (background, window) confidently returned the wrong element with
// `orientation: portrait` and no advisory (issue #34 review finding).

private let native = NativePortraitSize(width: 834, height: 1210)

@Suite("Point-query sole-orientation decision")
struct PointQueryOrientationTests {
    // Probe point (100,100) projects to:
    //   portrait             (100, 100)
    //   portrait-upside-down (734, 1110)
    //   landscape-right      (100, 734)
    //   landscape-left       (1110, 100)
    private let probePoint = CGPoint(x: 100, y: 100)

    @Test("small frame around the portrait projection settles portrait")
    func portraitUnique() {
        let frame = CGRect(x: 80, y: 80, width: 50, height: 50)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == .portrait)
    }

    @Test("small frame around a landscape projection settles that landscape")
    func landscapeUnique() {
        let frame = CGRect(x: 90, y: 700, width: 60, height: 60)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == .landscapeRight)
    }

    @Test("a full-screen frame containing every projection is ambiguous")
    func fatFrameAmbiguous() {
        // Regression: portrait used to win this tie.
        let frame = CGRect(x: 0, y: 0, width: 834, height: 1210)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == nil)
    }

    @Test("near-center probes are ambiguous even in small frames")
    func nearCenterAmbiguous() {
        // At the screen center every mapping projects onto (almost)
        // the same point, so containment proves nothing.
        let center = CGPoint(x: 417, y: 605)
        let frame = CGRect(x: 400, y: 590, width: 40, height: 30)
        let result = OrientationCalibrator.soleOrientation(
            mapping: center, into: frame, native: native
        )
        #expect(result == nil)
    }

    @Test("a frame containing no projection is ambiguous, not portrait")
    func inconsistentHitAmbiguous() {
        let frame = CGRect(x: 500, y: 500, width: 10, height: 10)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == nil)
    }

    @Test("containment honors the calibration slack")
    func slackHonored() {
        // Frame edge 1 pt away from the portrait projection — inside
        // the ±2 pt slack, so still a unique portrait match.
        let frame = CGRect(x: 101, y: 101, width: 40, height: 40)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == .portrait)
    }
}

// iPhone 12 mini: UI space 375x812, pixels / scale 360x780. The AX
// hit-test consumes UI-METRIC points on native-portrait AXES (verified
// live on iOS 26.4: querying the un-scaled UI point returns the element
// at that point, while the pixels/scale-shrunk point lands ~4% off),
// whereas HID dispatch normalizes against pixels/scale. These tests pin
// the two transforms apart.
private let mini = NativePortraitSize(width: 360, height: 780)
private let miniScale = UIPointScale(native: mini, uiPortrait: (width: 375, height: 812))!

private func miniCalibration(_ orientation: DisplayOrientation) -> OrientationCalibration {
    OrientationCalibration(
        orientation: orientation,
        native: mini,
        uiScale: miniScale,
        probesUsed: 1,
        advisory: nil
    )
}

@Suite("Probe vs HID space on display-downscaled devices")
struct DownscaledProbeSpaceTests {
    @Test("portrait probes pass through un-scaled")
    func portraitProbeIdentity() {
        // The Settings toolbar Dictate button center: the probe must
        // query exactly this UI point — shrinking it into the HID metric
        // would hit the neighbouring row.
        let p = miniCalibration(.portrait).probeCGPoint(CGPoint(x: 317.5, y: 760))
        #expect(p == CGPoint(x: 317.5, y: 760))
    }

    @Test("portrait HID dispatch carries the metric scale")
    func portraitHIDScales() {
        let calibration = miniCalibration(.portrait)
        #expect(!calibration.isIdentity)
        let p = calibration.hidCGPoint(CGPoint(x: 187.5, y: 674.5))
        #expect(abs(p.x - 180) < 0.001)
        #expect(abs(p.y - 674.5 * 780 / 812) < 0.001)
    }

    @Test("landscape probes rotate on the UI-sized canvas, HID on the scaled one")
    func landscapeProbeAndHIDDiverge() {
        let ui = CGPoint(x: 100, y: 200)
        // Axes only, on the 375x812 canvas: (375 − 200, 100).
        let probe = miniCalibration(.landscapeRight).probeCGPoint(ui)
        #expect(abs(probe.x - 175) < 0.001)
        #expect(abs(probe.y - 100) < 0.001)
        // HID additionally shrinks into the 360x780 metric.
        let hid = miniCalibration(.landscapeRight).hidCGPoint(ui)
        #expect(abs(hid.x - (360 - 200 * 360 / 375)) < 0.001)
        #expect(abs(hid.y - 100 * 780 / 812) < 0.001)
    }

    @Test("wrappedProbe forwards portrait probe points untouched")
    @MainActor
    func wrappedProbePortrait() async throws {
        final class Box: @unchecked Sendable { var received: CGPoint? }
        let box = Box()
        let probe = miniCalibration(.portrait).wrappedProbe { p in
            box.received = p
            return nil
        }
        _ = try await probe(CGPoint(x: 317.5, y: 760))
        #expect(box.received == CGPoint(x: 317.5, y: 760))
    }
}
