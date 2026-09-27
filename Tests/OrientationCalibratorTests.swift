// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// MARK: - Fixture helpers
//
// A mock "screen" is a list of labeled UI-space rects plus a ground-truth
// orientation. The probe receives a point on the hit-test's native-
// portrait AXES; on this 1:1 fixture the UI and pixels/scale metrics
// coincide, so mapping through the ground truth on the native canvas
// behaves exactly like the device did during the issue #34 verification.
// (Downscaled devices, where the metrics diverge, are pinned separately
// below.)

private let iPadNative = NativePortraitSize(width: 834, height: 1210)

private struct MockScreen {
    let truth: DisplayOrientation
    let elements: [CGRect]
    var probeCount = 0

    mutating func probe(_ framebufferPoint: CGPoint) -> [String: Any]? {
        probeCount += 1
        let ui = truth.framebufferToUI(framebufferPoint, native: iPadNative)
        guard let hit = elements.first(where: { $0.contains(ui) }) else { return nil }
        return [
            "role": "AXButton",
            "frame": [
                "x": hit.minX, "y": hit.minY,
                "width": hit.width, "height": hit.height,
            ] as [String: Any],
        ]
    }
}

/// Off-center small elements laid out in the UI space of `orientation`.
private func fixtureElements(for orientation: DisplayOrientation) -> [CGRect] {
    let ui = orientation.uiSize(native: iPadNative)
    return [
        CGRect(x: 26, y: 87, width: 288, height: 44),
        CGRect(x: 26, y: 564, width: 288, height: 53),
        CGRect(x: ui.width - 120, y: 40, width: 80, height: 30),
    ]
}

private let quietLogger = SimUseLogger(writeToStdErr: false)

@MainActor
private func run(
    truth: DisplayOrientation,
    elements: [CGRect]? = nil,
    uiScreenSize: (width: Double, height: Double)?,
    hint: (width: Double, height: Double)? = nil,
    discriminators: [CGRect]? = nil,
    maxProbes: Int = OrientationCalibrator.defaultMaxProbes
) async -> (result: OrientationCalibration, probes: Int) {
    let screenElements = elements ?? fixtureElements(for: truth)
    var screen = MockScreen(truth: truth, elements: screenElements)
    let box = ProbeBox(screen: screen)
    let result = await OrientationCalibrator.calibrate(
        native: iPadNative,
        uiScreenSize: uiScreenSize,
        hint: hint,
        discriminators: discriminators ?? screenElements,
        probe: { box.screen.probe($0) },
        maxProbes: maxProbes,
        logger: quietLogger
    )
    screen = box.screen
    return (result, screen.probeCount)
}

/// Reference box so the probe closure can mutate the mock's counter.
@MainActor
private final class ProbeBox {
    var screen: MockScreen
    init(screen: MockScreen) { self.screen = screen }
}

// MARK: - Tests

@MainActor
@Suite("OrientationCalibrator")
struct OrientationCalibratorTests {
    @Test("resolves every ground truth", arguments: DisplayOrientation.allCases)
    func resolvesGroundTruth(truth: DisplayOrientation) async {
        let ui = truth.uiSize(native: iPadNative)
        let (result, _) = await run(truth: truth, uiScreenSize: ui)
        #expect(result.orientation == truth)
        #expect(result.advisory == nil)
    }

    @Test("portrait confirms in exactly one probe")
    func portraitFastPath() async {
        let (result, probes) = await run(truth: .portrait, uiScreenSize: (834, 1210))
        #expect(result.orientation == .portrait)
        #expect(result.probesUsed == 1)
        #expect(probes == 1)
    }

    @Test("swapped dims prune to the landscape pair")
    func dimsPruning() async {
        // A landscape truth with matching uiScreenSize must never guess a
        // portrait variant, even when probes are exhausted: feed it only
        // nil-returning discriminators (off-screen rects).
        let offscreen = [CGRect(x: 2000, y: 2000, width: 10, height: 10)]
        let (result, _) = await run(
            truth: .landscapeRight,
            elements: [],
            uiScreenSize: (1210, 834),
            discriminators: offscreen
        )
        #expect(result.orientation.swapsDimensions)
        #expect(result.advisory != nil)
    }

    @Test("stale-snapshot hint orders landscape candidates first")
    func hintOrdering() async {
        // No fresh uiScreenSize (tap-alias path); the snapshot said
        // landscape. The first probe should already assume landscape and
        // confirm the truth in one round trip.
        let (result, probes) = await run(
            truth: .landscapeRight,
            uiScreenSize: nil,
            hint: (1210, 834)
        )
        #expect(result.orientation == .landscapeRight)
        #expect(probes == 1)
        #expect(result.advisory == nil)
    }

    @Test("centered discriminators are skipped without probing")
    func centeredSkipped() async {
        let centered = CGRect(x: 377, y: 565, width: 80, height: 80) // center of 834×1210
        let offCenter = CGRect(x: 26, y: 87, width: 288, height: 44)
        // The 180° mirror of `offCenter` — what a probe assuming portrait
        // physically lands on when the device is actually upside down.
        let mirror = CGRect(x: 520, y: 1080, width: 288, height: 44)
        let (result, probes) = await run(
            truth: .portraitUpsideDown,
            elements: [centered, offCenter, mirror],
            uiScreenSize: (834, 1210),
            discriminators: [centered, offCenter]
        )
        #expect(result.orientation == .portraitUpsideDown)
        #expect(probes == 1) // the centered rect never reached the probe
    }

    @Test("full-screen wrapper hits are uninformative, not fatal")
    func fatWrapperUninformative() async {
        // First discriminator lands on a giant background element whose
        // frame contains every candidate's projection; the next, smaller
        // one settles it.
        let background = CGRect(x: 0, y: 0, width: 834, height: 1210)
        let small = CGRect(x: 26, y: 87, width: 288, height: 44)
        // Discriminator that only exists in the probe world as background:
        let ghost = CGRect(x: 500, y: 900, width: 40, height: 40)
        let (result, probes) = await run(
            truth: .portraitUpsideDown,
            elements: [small, background],
            uiScreenSize: (834, 1210),
            discriminators: [ghost, small]
        )
        #expect(result.orientation == .portraitUpsideDown)
        #expect(probes == 2)
    }

    @Test("all-nil probes fall back to the prior with an advisory")
    func allNilFallsBack() async {
        let discriminators = [
            CGRect(x: 26, y: 87, width: 288, height: 44),
            CGRect(x: 26, y: 564, width: 288, height: 53),
            CGRect(x: 700, y: 40, width: 80, height: 30),
            CGRect(x: 100, y: 1100, width: 60, height: 30),
        ]
        let (result, probes) = await run(
            truth: .portrait, // irrelevant — screen is empty
            elements: [],
            uiScreenSize: (834, 1210),
            discriminators: discriminators
        )
        #expect(result.orientation == .portrait) // prior, not demotion order
        #expect(result.advisory?.kind == .orientationCalibrationFallback)
        #expect(probes <= OrientationCalibrator.defaultMaxProbes)
    }

    @Test("throwing probes degrade like nil probes")
    func throwingProbes() async {
        let result = await OrientationCalibrator.calibrate(
            native: iPadNative,
            uiScreenSize: (834, 1210),
            discriminators: fixtureElements(for: .portrait),
            probe: { _ in throw CLIError(errorDescription: "boom") },
            logger: quietLogger
        )
        #expect(result.orientation == .portrait)
        #expect(result.advisory != nil)
    }

    @Test("probe budget is respected")
    func budgetRespected() async {
        // Every probe hits the full-screen wrapper — informative never.
        let background = CGRect(x: 0, y: 0, width: 834, height: 1210)
        let discriminators = (0..<10).map { i in
            CGRect(x: 30 + Double(i) * 5, y: 90, width: 40, height: 20)
        }
        let (result, probes) = await run(
            truth: .portraitUpsideDown,
            elements: [background],
            uiScreenSize: (834, 1210),
            discriminators: discriminators
        )
        #expect(probes == OrientationCalibrator.defaultMaxProbes)
        #expect(result.advisory != nil)
    }

    @Test("missing native size degrades to identity with advisory")
    func missingNative() async {
        let result = await OrientationCalibrator.calibrate(
            native: nil,
            uiScreenSize: nil,
            discriminators: [],
            probe: { _ in nil },
            logger: quietLogger
        )
        #expect(result.orientation == .portrait)
        #expect(result.advisory?.kind == .orientationCalibrationFallback)
        #expect(result.hidPoint(x: 100, y: 200) == (100, 200))
    }

    @Test("stale snapshot advisory fires only on dimension mismatch")
    func staleSnapshotAdvisory() {
        func payload(width: Int, height: Int) -> OutlineCache.Payload {
            OutlineCache.Payload(
                version: OutlineCache.currentVersion,
                udid: "TEST",
                capturedAt: "2026-07-08T00:00:00Z",
                screen: .init(width: width, height: height),
                entries: []
            )
        }
        let landscape = OrientationCalibration(
            orientation: .landscapeRight, native: iPadNative, probesUsed: 1, advisory: nil
        )
        // Snapshot captured in the same landscape orientation — no advisory.
        #expect(IOSSimTapCommand.staleSnapshotAdvisory(
            calibration: landscape, payload: payload(width: 1210, height: 834)
        ) == nil)
        // Snapshot captured in portrait, device now landscape — stale.
        let advisory = IOSSimTapCommand.staleSnapshotAdvisory(
            calibration: landscape, payload: payload(width: 834, height: 1210)
        )
        #expect(advisory?.kind == .orientationCalibrationFallback)
        #expect(advisory?.message.contains("834x1210") == true)
    }

    @Test("orientation advisory kind survives an encode/decode round trip")
    func advisoryKindRoundTrip() throws {
        let advisory = CommandAdvisory(
            kind: .orientationCalibrationFallback,
            message: "assuming portrait"
        )
        let data = try JSONEncoder().encode(advisory)
        let decoded = try JSONDecoder().decode(CommandAdvisory.self, from: data)
        #expect(decoded == advisory)
        #expect(String(decoding: data, as: UTF8.self).contains("orientation_calibration_fallback"))
    }

    @Test("hidPoint transforms only when non-identity")
    func hidPointTransform() {
        let landscape = OrientationCalibration(
            orientation: .landscapeLeft, native: iPadNative, probesUsed: 1, advisory: nil
        )
        // landscapeLeft inverse: f = (uy, H−ux) = (332, 1210−770) = (332, 440).
        let p = landscape.hidPoint(x: 770, y: 332)
        #expect(p == (332, 440))

        let portrait = OrientationCalibration(
            orientation: .portrait, native: iPadNative, probesUsed: 1, advisory: nil
        )
        #expect(portrait.hidPoint(x: 770, y: 332) == (770, 332))
    }
}

// MARK: - Display-downscaled devices
//
// The hit-test XPC shares HID's native-portrait AXES but NOT its metric:
// it consumes points in the UI point METRIC. Verified live on iPhone 12
// mini / iOS 26.4 (Settings.app): querying the un-scaled UI point returns
// the element at that point, while the pixels/scale-shrunk point lands
// ~4% off target. Only HID dispatch normalizes against pixels/scale.
// These mocks therefore interpret the probe point on the UI-sized
// portrait canvas (375x812 on the mini), never on 360x780.

private let miniNative = NativePortraitSize(width: 360, height: 780)

@MainActor
private final class ProbeLog {
    var points: [CGPoint] = []
}

private func frameDict(_ rect: CGRect) -> [String: Any] {
    [
        "role": "AXButton",
        "frame": [
            "x": rect.minX, "y": rect.minY,
            "width": rect.width, "height": rect.height,
        ] as [String: Any],
    ]
}

@MainActor
@Suite("OrientationCalibrator on display-downscaled devices")
struct DownscaledCalibratorTests {
    @Test("portrait confirms with un-scaled probe points")
    func downscaledPortraitProbes() async {
        // The Settings toolbar Dictate button (17x22) — small enough that
        // a probe shrunk into the HID metric (~4% off) misses it.
        let dictate = CGRect(x: 309, y: 749, width: 17, height: 22)
        let row = CGRect(x: 16, y: 630, width: 343, height: 52)
        let log = ProbeLog()
        let result = await OrientationCalibrator.calibrate(
            native: miniNative,
            uiScreenSize: (375, 812),
            discriminators: [dictate, row],
            probe: { p in
                log.points.append(p)
                // Portrait truth: the UI-metric portrait-axis point IS
                // the UI point.
                return [dictate, row].first(where: { $0.contains(p) }).map(frameDict)
            },
            logger: quietLogger
        )
        #expect(result.orientation == .portrait)
        #expect(result.advisory == nil)
        #expect(!result.uiScale.isIdentity)
        #expect(log.points.first == CGPoint(x: 317.5, y: 760))
    }

    @Test("landscape probes rotate on the UI-sized canvas")
    func downscaledLandscapeProbes() async {
        // A small element in landscape-right UI space (812x375). The
        // hit-test's inverse mapping runs on the UI-sized canvas:
        // ui = (p.y, 375 − p.x).
        let smallLandscape = CGRect(x: 795, y: 40, width: 16, height: 22)
        let log = ProbeLog()
        let result = await OrientationCalibrator.calibrate(
            native: miniNative,
            uiScreenSize: (812, 375),
            discriminators: [smallLandscape],
            probe: { p in
                log.points.append(p)
                let ui = CGPoint(x: p.y, y: 375 - p.x)
                return smallLandscape.contains(ui) ? frameDict(smallLandscape) : nil
            },
            logger: quietLogger
        )
        #expect(result.orientation == .landscapeRight)
        #expect(result.advisory == nil)
        // center (803, 51) → portrait axes on the 375x812 canvas:
        // (375 − 51, 803) = (324, 803).
        #expect(log.points.first == CGPoint(x: 324, y: 803))
    }
}
