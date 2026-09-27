// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import AVFoundation
import CoreMedia
import ImageIO

@Suite("Android Record Video Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidRecordVideoTests {
    @Test("android record-video produces a loadable MP4 with a video track")
    func recordVideoSubcommand() async throws {
        let result = try await recordForDuration(arguments: ["android", "record-video"], duration: 4.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("Recording Android device"))
        #expect(result.fileSize > 10_000, "recorded file should be non-empty, got \(result.fileSize)")
        try await Self.expectValidMP4(at: result.outputURL)
    }

    @Test("top-level record-video routes an adb serial to the same engine")
    func recordVideoTopLevel() async throws {
        let result = try await recordForDuration(arguments: ["record-video"], duration: 4.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("Recording Android device"))
        try await Self.expectValidMP4(at: result.outputURL)
    }

    @Test("recording survives a screenrecord segment restart with one continuous MP4")
    func recordAcrossSegmentRestart() async throws {
        // 2-second forced segments over a ~6 s recording guarantee at
        // least one restart. Proving the restart actually CONTRIBUTED
        // frames needs care on two fronts:
        //
        //   * screenrecord is VFR and a static screen can leave a whole
        //     segment frameless — drive screen activity for the entire
        //     recording so every segment has real frames to deliver.
        //     The playground main screen ignores vertical swipes (nothing
        //     scrolls), which starves the encoder no matter how hard the
        //     driver swipes — so bring up the scroll-test list first, and
        //     alternate the swipe direction because one-way swipes
        //     saturate at the end of the list and stop changing pixels.
        //   * `finish(stopHostTime:)` re-appends the last access unit at
        //     the stop time to keep the final image visible, so duration
        //     and isPlayable look healthy even if the muxer dropped
        //     everything after segment 1. The discriminating assertion is
        //     a real sample INSIDE the post-restart window (2.5–5.5 s):
        //     segment-1 frames sit below ~2.3 s and the trailing
        //     re-append lands at ~6 s, so only frames muxed from a later
        //     segment can appear there.
        let serial = try AndroidE2E.requireSerial()
        let adbPath = try AndroidE2E.adbPath()
        try await AndroidE2E.launch(screen: "scroll-test")
        let activityDriver = Task {
            for index in 0..<7 {
                if Task.isCancelled { break }
                let swipe = Process()
                swipe.executableURL = URL(fileURLWithPath: adbPath)
                let (fromY, toY) = index.isMultiple(of: 2) ? ("1500", "600") : ("600", "1500")
                swipe.arguments = ["-s", serial, "shell", "input", "swipe", "500", fromY, "500", toY, "200"]
                swipe.standardOutput = Pipe()
                swipe.standardError = Pipe()
                try? swipe.run()
                swipe.waitUntilExit()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        defer { activityDriver.cancel() }

        let result = try await recordForDuration(
            arguments: ["android", "record-video"],
            duration: 6.0,
            environment: ["SIM_USE_SCREENRECORD_TIME_LIMIT": "2"]
        )
        activityDriver.cancel()
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("restarting"), "expected a forced segment restart, stderr: \(result.stderr)")
        try await Self.expectValidMP4(at: result.outputURL)

        let asset = AVURLAsset(url: result.outputURL)
        let playable = try await asset.load(.isPlayable)
        #expect(playable, "restart-spanning mp4 should be playable")
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 3.0, "expected media beyond one 2 s segment, got \(duration)s")

        let samplePTS = try await Self.videoSamplePTS(of: asset)
        #expect(samplePTS == samplePTS.sorted(), "sample PTS must be non-decreasing across segments")
        let postRestartSamples = samplePTS.filter { $0 > 2.5 && $0 < 5.5 }
        #expect(
            !postRestartSamples.isEmpty,
            "no samples in the post-restart window — later segments were not muxed. PTS: \(samplePTS.map { String(format: "%.2f", $0) })"
        )
    }

    @Test("android record-video --format gif produces an animated GIF")
    func recordVideoGIF() async throws {
        // screenrecord is VFR: a static screen can starve the encoder down
        // to a single frame, which would make the animation assertion
        // flaky — drive swipes so the GIF has real motion to sample.
        let serial = try AndroidE2E.requireSerial()
        let adbPath = try AndroidE2E.adbPath()
        try await AndroidE2E.launch(screen: "scroll-test")
        let activityDriver = Task {
            for index in 0..<5 {
                if Task.isCancelled { break }
                let swipe = Process()
                swipe.executableURL = URL(fileURLWithPath: adbPath)
                let (fromY, toY) = index.isMultiple(of: 2) ? ("1500", "600") : ("600", "1500")
                swipe.arguments = ["-s", serial, "shell", "input", "swipe", "500", fromY, "500", toY, "200"]
                swipe.standardOutput = Pipe()
                swipe.standardError = Pipe()
                try? swipe.run()
                swipe.waitUntilExit()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        defer { activityDriver.cancel() }

        let result = try await recordForDuration(
            arguments: ["android", "record-video", "--format", "gif"],
            duration: 4.0,
            fileExtension: "gif"
        )
        activityDriver.cancel()
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("Transcoding to GIF"), "stderr: \(result.stderr)")
        #expect(result.stderr.contains("GIF written"), "stderr: \(result.stderr)")

        let frameCount = try Self.animatedGIFFrameCount(at: result.outputURL)
        #expect(frameCount > 1, "expected an animated GIF, got \(frameCount) frame(s)")

        let intermediateMP4 = URL(fileURLWithPath: result.outputURL.path + ".recording.mp4")
        #expect(
            !FileManager.default.fileExists(atPath: intermediateMP4.path),
            "intermediate MP4 should be removed after a successful transcode"
        )
    }

    // MARK: - Helpers

    /// Asserts the GIF magic and returns the frame count.
    private static func animatedGIFFrameCount(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let magic = String(decoding: data.prefix(6), as: UTF8.self)
        #expect(magic == "GIF89a" || magic == "GIF87a", "not a GIF file (magic: \(magic))")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "GIF not readable by ImageIO")
        return CGImageSourceGetCount(source)
    }

    /// Presentation timestamps of every video sample, read pass-through
    /// (no decode) so assertions can see the real muxed sample layout
    /// rather than AVAsset's summarized duration.
    private static func videoSamplePTS(of asset: AVURLAsset) async throws -> [Double] {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first, "mp4 has no video track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var pts: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if stamp.isValid {
                pts.append(stamp.seconds)
            }
        }
        return pts
    }

    private static func expectValidMP4(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        #expect(!tracks.isEmpty, "mp4 has no tracks (moov atom likely missing)")
        #expect(tracks.contains { $0.mediaType == .video }, "mp4 has no video track")
    }

    private func recordForDuration(
        arguments: [String],
        duration: TimeInterval,
        environment: [String: String] = [:],
        fileExtension: String = "mp4"
    ) async throws -> (outputURL: URL, fileSize: Int, stderr: String, exitCode: Int32) {
        let serial = try AndroidE2E.requireSerial()
        let simUsePath = try TestHelpers.getSimUsePath()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-android-record-\(UUID().uuidString).\(fileExtension)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = arguments + ["--device", serial, "--output", outputURL.path]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        process.terminate()

        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 15.0,
            description: "record-video did not exit after SIGTERM"
        )

        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return (outputURL: outputURL, fileSize: size, stderr: stderrText, exitCode: process.terminationStatus)
    }
}
