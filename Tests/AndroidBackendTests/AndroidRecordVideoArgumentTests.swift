// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import AndroidBackend

@Suite("Android record-video argument construction")
struct AndroidRecordVideoArgumentTests {
    @Test("parseWMSize reads Physical size")
    func physicalSize() {
        let parsed = AndroidRecordVideoCommand.parseWMSize("Physical size: 1080x2400\n")
        #expect(parsed?.width == 1080)
        #expect(parsed?.height == 2400)
    }

    @Test("parseWMSize prefers an Override size over Physical size")
    func overrideSizePreferred() {
        let output = "Physical size: 1080x2400\nOverride size: 720x1600\n"
        let parsed = AndroidRecordVideoCommand.parseWMSize(output)
        #expect(parsed?.width == 720)
        #expect(parsed?.height == 1600)
    }

    @Test("parseWMSize returns nil for unparseable output")
    func unparseable() {
        #expect(AndroidRecordVideoCommand.parseWMSize("cannot connect to display\n") == nil)
    }

    @Test("screenrecordArguments omits --time-limit below API 34")
    func api33NoTimeLimit() {
        let args = AndroidRecordVideoCommand.screenrecordArguments(serial: "emu-1", sdk: 33, bitrate: nil, size: nil)
        #expect(args == ["-s", "emu-1", "exec-out", "screenrecord", "--output-format=h264", "-"])
    }

    @Test("screenrecordArguments adds --time-limit 0 on API 34+")
    func api34Unlimited() {
        let args = AndroidRecordVideoCommand.screenrecordArguments(serial: "emu-1", sdk: 34, bitrate: nil, size: nil)
        #expect(args.contains("--time-limit"))
        #expect(args.contains("0"))
        #expect(args.last == "-")
    }

    @Test("screenrecordArguments includes --bit-rate and --size when provided")
    func bitrateAndSize() {
        let args = AndroidRecordVideoCommand.screenrecordArguments(serial: "emu-1", sdk: 34, bitrate: 4_000_000, size: (width: 540, height: 1200))
        #expect(args == [
            "-s", "emu-1", "exec-out", "screenrecord", "--output-format=h264",
            "--time-limit", "0",
            "--bit-rate", "4000000",
            "--size", "540x1200",
            "-",
        ])
    }

    // Regression: --quality must map to --bit-rate at the default scale too.
    // `recordVideoAndroidStream` derives bitrate from `bitrateSize` (which
    // falls back to the unscaled detected size when scale == 1.0), then
    // always passes it to screenrecordArguments — only the --size argument
    // itself is scale-gated.
    @Test("screenrecordArguments passes --bit-rate without --size (default scale)")
    func bitrateWithoutSizeAtDefaultScale() {
        let args = AndroidRecordVideoCommand.screenrecordArguments(serial: "emu-1", sdk: 34, bitrate: 4_000_000, size: nil)
        #expect(args.contains("--bit-rate"))
        #expect(args.contains("4000000"))
        #expect(!args.contains("--size"))
    }

    @Test("screenrecordArguments honors the time-limit override on API 34+")
    func timeLimitOverrideAPI34() {
        let args = AndroidRecordVideoCommand.screenrecordArguments(serial: "emu-1", sdk: 34, bitrate: nil, size: nil, timeLimitOverride: 5)
        #expect(args == ["-s", "emu-1", "exec-out", "screenrecord", "--output-format=h264", "--time-limit", "5", "-"])
    }

    @Test("time-limit override applies below API 34 too")
    func timeLimitOverrideAPI33() {
        let args = AndroidRecordVideoCommand.screenrecordArguments(serial: "emu-1", sdk: 33, bitrate: nil, size: nil, timeLimitOverride: 5)
        #expect(args.contains("--time-limit"))
        #expect(args.contains("5"))
    }

    @Test("screenrecordTimeLimitOverride parses the debug env var")
    func timeLimitOverrideEnvParsing() {
        #expect(AndroidRecordVideoCommand.screenrecordTimeLimitOverride(environment: [:]) == nil)
        #expect(AndroidRecordVideoCommand.screenrecordTimeLimitOverride(environment: ["SIM_USE_SCREENRECORD_TIME_LIMIT": "3"]) == 3)
        #expect(AndroidRecordVideoCommand.screenrecordTimeLimitOverride(environment: ["SIM_USE_SCREENRECORD_TIME_LIMIT": "0"]) == nil)
        #expect(AndroidRecordVideoCommand.screenrecordTimeLimitOverride(environment: ["SIM_USE_SCREENRECORD_TIME_LIMIT": "abc"]) == nil)
    }

    @Test("scaledSize halves dimensions and rounds down to even")
    func scaledSizeRounding() {
        let scaled = AndroidRecordVideoCommand.scaledSize((width: 1081, height: 2401), scale: 0.5)
        #expect(scaled.width == 540)
        #expect(scaled.height == 1200)
    }

    @Test("scaledSize at 1.0 returns the input unchanged (already even)")
    func scaledSizeIdentity() {
        let scaled = AndroidRecordVideoCommand.scaledSize((width: 1080, height: 2400), scale: 1.0)
        #expect(scaled.width == 1080)
        #expect(scaled.height == 2400)
    }
}
