// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl
import SimUseCore
import iOSSimBackend

public struct VideoStreamConfiguration: Sendable, Equatable {
    public let framesPerSecond: Int
    public let quality: Int
    public let scale: Double

    public init(framesPerSecond: Int = 10, quality: Int = 80, scale: Double = 1.0) {
        self.framesPerSecond = framesPerSecond
        self.quality = quality
        self.scale = scale
    }
}

/// One frame from the application-facing stream API. Unlike the CLI
/// `stream-video` command, frames are returned to the caller and never
/// written to stdout.
public struct VideoFrame: Sendable, Equatable {
    public let jpegData: Data
    public let timestamp: Date

    public init(jpegData: Data, timestamp: Date = Date()) {
        self.jpegData = jpegData
        self.timestamp = timestamp
    }
}

public extension SimUseClient {
    /// Streams JPEG frames from an iOS Simulator as an async sequence.
    /// Cancellation of the consuming task cancels screenshot production.
    func streamVideo(
        on deviceID: SimulatorID,
        configuration: VideoStreamConfiguration = .init()
    ) async throws -> AsyncThrowingStream<VideoFrame, Error> {
        guard !deviceID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimUseError.invalidRequest("Device ID must not be empty.")
        }
        do {
            try IOSSimStreamVideoCommand.validateOptions(
                fps: configuration.framesPerSecond,
                quality: configuration.quality,
                scale: configuration.scale
            )
            let logger = SimUseLogger()
            try await performGlobalSetup(logger: logger)
            let simulatorSet = try await getSimulatorSet(
                deviceSetPath: nil,
                logger: logger,
                reporter: EmptyEventReporter.shared
            )
            guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == deviceID.rawValue }) else {
                throw SimUseError.deviceNotFound("Simulator \(deviceID.rawValue) was not found.")
            }
            guard simulator.state == .booted else {
                throw SimUseError.deviceNotBooted("Simulator \(deviceID.rawValue) is not booted.")
            }

            let interval = 1.0 / Double(configuration.framesPerSecond)
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    defer { continuation.finish() }
                    while !Task.isCancelled {
                        let started = Date()
                        do {
                            let pngData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                            let jpegData = try await VideoFrameUtilities.processJPEGData(
                                pngData,
                                scale: configuration.scale,
                                quality: configuration.quality
                            )
                            continuation.yield(VideoFrame(jpegData: jpegData, timestamp: Date()))
                        } catch {
                            continuation.finish(throwing: SimUseError.map(error, deviceID: deviceID.rawValue))
                            return
                        }
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed < interval {
                            try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000))
                        }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        } catch let error as SimUseError {
            throw error
        } catch {
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }
}
