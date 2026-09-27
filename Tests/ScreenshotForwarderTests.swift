// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Screenshot`,
// `IOSSimScreenshotCommand`, and `AndroidScreenshotCommand`.
@Suite("Screenshot forwarder")
@MainActor
struct ScreenshotForwarderTests {

    // MARK: - Symmetric forwarder contract

    @Test("AndroidScreenshotCommand.performScreenshot is callable with the forwarder's argument shape")
    func androidScreenshotPerformContract() {
        let _: (
            String,
            AndroidDeviceController
        ) throws -> Data = AndroidScreenshotCommand.performScreenshot
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Screenshot and IOSSimScreenshotCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "--output", "/tmp/shot.png",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json",
        ]
        let topLevel = try Screenshot.parse(argv)
        let subCmd = try IOSSimScreenshotCommand.parse(argv)

        #expect(topLevel.output == "/tmp/shot.png")
        #expect(subCmd.output == "/tmp/shot.png")
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }

    @Test("Both surfaces opt out of the daemon (capture is fast enough that the spawn cost dwarfs the saving)")
    func bothBypassDaemon() throws {
        let topLevel = try Screenshot.parse([])
        let subCmd = try IOSSimScreenshotCommand.parse([])
        #expect(topLevel.daemonBypass)
        #expect(subCmd.daemonBypass)
    }

    // MARK: - Output path resolution

    @Test("Default iOS output filename embeds the simulator name")
    func defaultIOSOutputName() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: nil,
            simulatorName: "iPhone 17 Pro"
        )
        #expect(url.lastPathComponent.hasPrefix("Simulator Screenshot - iPhone 17 Pro - "))
        #expect(url.pathExtension == "png")
    }

    @Test("A simulator name containing path separators stays a single filename component")
    func slashedSimulatorNameStaysSingleComponent() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: nil,
            simulatorName: "My iPhone/Work"
        )
        #expect(url.deletingLastPathComponent().path == FileManager.default.currentDirectoryPath)
        #expect(url.lastPathComponent.hasPrefix("Simulator Screenshot - My iPhone-Work - "))
    }

    @Test("A traversal-shaped simulator name cannot escape the current directory")
    func traversalSimulatorNameResolvesIntoCwd() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: nil,
            simulatorName: "../../evil"
        )
        #expect(url.deletingLastPathComponent().path == FileManager.default.currentDirectoryPath)
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test("Tilde-prefixed --output expands the home directory")
    func tildeExpansion() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: "~/sim-use-tests/shot.png",
            simulatorName: "iPhone 17 Pro"
        )
        #expect(url.path.hasPrefix(NSHomeDirectory()))
        #expect(url.lastPathComponent == "shot.png")
        // Best-effort cleanup so successive runs stay idempotent.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}