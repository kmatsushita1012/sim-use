// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Screenshot Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidScreenshotTests {
    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

    /// The bridge captures via `AccessibilityService.takeScreenshot`, which
    /// enforces a ~500 ms minimum interval between calls; the back-to-back
    /// tests in this serialized suite trip it and fail with
    /// `screenshot_failed`. Settle past the window before each capture.
    private static func settleScreenshotRateLimit() async throws {
        try await Task.sleep(nanoseconds: 600_000_000)
    }

    @Test("android screenshot writes a real PNG to the given path")
    func screenshotToFile() async throws {
        try await Self.settleScreenshotRateLimit()
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-android-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try await CommandRunner.run("\(simUsePath) android screenshot --device \(serial) --output \(output.path)")

        let data = try Data(contentsOf: output)
        #expect(data.prefix(4) == Self.pngMagic)
        #expect(data.count > 10_000, "screenshot should be a real image, got \(data.count) bytes")
    }

    @Test("android screenshot --output - streams raw PNG bytes to stdout")
    func screenshotToStdout() async throws {
        try await Self.settleScreenshotRateLimit()
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = ["android", "screenshot", "--device", serial, "--output", "-"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        let stdoutReadTask = Task {
            try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        try process.run()
        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 30.0,
            description: "android screenshot --output - did not exit"
        )

        let data = (try? await stdoutReadTask.value) ?? Data()
        #expect(process.terminationStatus == 0)
        #expect(data.prefix(4) == Self.pngMagic, "stdout should carry raw PNG bytes")
        #expect(data.count > 10_000)
    }

    @Test("top-level screenshot routes an adb serial to the Android engine")
    func screenshotTopLevel() async throws {
        try await Self.settleScreenshotRateLimit()
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-android-top-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try await CommandRunner.run("\(simUsePath) screenshot --udid \(serial) --output \(output.path)")

        let data = try Data(contentsOf: output)
        #expect(data.prefix(4) == Self.pngMagic)
        #expect(data.count > 10_000)
    }
}
