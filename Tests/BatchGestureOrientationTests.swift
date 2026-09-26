// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Batch gesture steps have their own primitive-construction path
// (issue #66): directional presets must ride the batch-wide
// calibration exactly like tap selector steps — computed once per
// run, shared across steps, degrading to an identity dispatch with a
// recorded advisory instead of failing the batch. Multi-touch presets
// stay on the raw legacy path and must not pay for a tree fetch.
// Endpoint math itself is pinned by GestureOrientationMappingTests.

private func makeSmallTree() throws -> [AccessibilityElement] {
    let json = """
    [{"type": "Application", "AXLabel": "App", "frame": {"x": 0, "y": 0, "width": 1376, "height": 1032}, "children": [
        {"type": "Button", "AXLabel": "Corner", "frame": {"x": 10, "y": 900, "width": 100, "height": 40}, "enabled": true}
    ]}]
    """
    return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

private let quietLogger = SimUseLogger(writeToStdErr: false)

@MainActor
private final class CalibratorSpy {
    private(set) var calls = 0
    let result: OrientationCalibration

    init(result: OrientationCalibration) {
        self.result = result
    }

    func record() -> OrientationCalibration {
        calls += 1
        return result
    }
}

@Suite("Batch — gesture orientation")
@MainActor
struct BatchGestureOrientationTests {
    private func parseStep(_ tokens: [String], context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    @Test("Directional gesture steps share one batch-wide calibration")
    func directionalStepsShareCalibration() async throws {
        let spy = CalibratorSpy(result: OrientationCalibration(
            orientation: .landscapeRight,
            native: NativePortraitSize(width: 1032, height: 1376),
            probesUsed: 1,
            advisory: nil
        ))
        let tree = try makeSmallTree()
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in tree },
            calibrator: { _, _, _ in spy.record() }
        )

        let first = try await parseStep(["gesture", "scroll-up"], context: context)
        let second = try await parseStep(["gesture", "scroll-left"], context: context)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(spy.calls == 1)
        #expect(context.commandAdvisories.isEmpty)
    }

    @Test("Multi-touch presets never pay for a tree fetch or calibration")
    func multiTouchStaysRaw() async throws {
        let spy = CalibratorSpy(result: .identity())
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in
                Issue.record("multi-touch preset should not fetch the AX tree")
                return []
            },
            calibrator: { _, _, _ in spy.record() }
        )

        let primitives = try await parseStep(["gesture", "pinch-in"], context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
    }

    @Test("An unreachable AX tree degrades to identity with a recorded advisory")
    func fetchFailureDegradesWithAdvisory() async throws {
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in throw CLIError(errorDescription: "no simulator") },
            calibrator: { _, _, _ in
                Issue.record("calibrator should not run when the tree fetch fails")
                return .identity()
            }
        )

        let primitives = try await parseStep(["gesture", "scroll-up"], context: context)

        #expect(primitives.count == 1)
        #expect(context.commandAdvisories.count == 1)
        let advisory = try #require(context.commandAdvisories.first)
        #expect(advisory.kind == .orientationCalibrationFallback)
        #expect(advisory.message.hasPrefix("Step 1: "))
        #expect(advisory.message.contains("scroll-up"))
    }
}
