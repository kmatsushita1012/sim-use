// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import FBSimulatorControl
@preconcurrency import FBControlCore
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
    ///
    /// The stream is backed by FBSimulatorControl's MJPEG video stream. It
    /// does not search for a Simulator window and does not invoke a CLI
    /// process, so it remains independent from the current desktop and
    /// display lock state.
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
            let logger = SimUseLogger(silent: true)
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

            let streamConfiguration = FBVideoStreamConfiguration(
                encoding: .MJPEG,
                framesPerSecond: NSNumber(value: configuration.framesPerSecond),
                compressionQuality: NSNumber(value: Double(configuration.quality) / 100.0),
                scaleFactor: NSNumber(value: configuration.scale),
                avgBitrate: nil,
                keyFrameRate: nil
            )
            let videoStream = try await awaitFutureValue(
                simulator.createStream(with: streamConfiguration)
            )
            let bridge = MJPEGVideoStreamBridge(
                videoStream: videoStream,
                deviceID: deviceID
            )
            do {
                try await bridge.start()
            } catch {
                bridge.finish(throwing: SimUseError.map(error, deviceID: deviceID.rawValue))
                throw SimUseError.map(error, deviceID: deviceID.rawValue)
            }

            return bridge.frames
        } catch let error as SimUseError {
            throw error
        } catch {
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }
}

private func awaitFutureValue<T: AnyObject>(_ future: FBFuture<T>) async throws -> T {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            future.onQueue(DispatchQueue.global(qos: .utility), notifyOfCompletion: { resolvedFuture in
                if let error = resolvedFuture.error {
                    continuation.resume(throwing: error)
                } else if let result = resolvedFuture.result {
                    continuation.resume(returning: result as! T)
                } else {
                    continuation.resume(throwing: MJPEGStreamError.futureResolvedWithoutResult)
                }
            })
        }
    } onCancel: {
        future.cancel()
    }
}

private func awaitFuture(_ future: FBFuture<NSNull>) async throws {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            future.onQueue(DispatchQueue.global(qos: .utility), notifyOfCompletion: { resolvedFuture in
                if let error = resolvedFuture.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    } onCancel: {
        future.cancel()
    }
}

private enum MJPEGStreamError: Error {
    case futureResolvedWithoutResult
}

private final class MJPEGVideoStreamBridge: @unchecked Sendable {
    let frames: AsyncThrowingStream<VideoFrame, Error>

    private let videoStream: any FBVideoStream
    private let deviceID: SimulatorID
    private let continuationBox: ContinuationBox
    private let assembler = MJPEGFrameAssembler()
    private let stateLock = NSLock()
    private var consumer: (any FBDataConsumer)?
    private var hasFinished = false

    init(videoStream: any FBVideoStream, deviceID: SimulatorID) {
        self.videoStream = videoStream
        self.deviceID = deviceID

        let continuationBox = ContinuationBox()
        self.continuationBox = continuationBox
        self.frames = AsyncThrowingStream { continuation in
            continuationBox.set(continuation)
        }
        continuationBox.setTerminationHandler { [weak self] _ in
            self?.stop()
        }
    }

    func start() async throws {
        let consumer = FBBlockDataConsumer.asynchronousDataConsumer { [weak self] data in
            self?.receive(data)
        }
        store(consumer: consumer)

        let startFuture = videoStream.startStreaming(consumer)
        videoStream.completed.onQueue(DispatchQueue.global(qos: .utility), notifyOfCompletion: { [weak self] (future: FBFuture<AnyObject>) in
            if let error = future.error {
                self?.finish(throwing: SimUseError.map(error, deviceID: self?.deviceID.rawValue ?? ""))
            } else {
                self?.finish()
            }
        })

        try await awaitFuture(startFuture)
    }

    private func receive(_ data: Data) {
        let extractedFrames = assembler.append(data)
        for jpegData in extractedFrames {
            continuationBox.yield(VideoFrame(jpegData: jpegData))
        }
    }

    private func store(consumer: any FBDataConsumer) {
        stateLock.lock()
        self.consumer = consumer
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        guard hasFinished == false else {
            stateLock.unlock()
            return
        }
        hasFinished = true
        stateLock.unlock()

        Task {
            _ = try? await awaitFuture(videoStream.stopStreaming())
            continuationBox.finish()
            clearConsumer()
        }
    }

    func finish(throwing error: Error? = nil) {
        stateLock.lock()
        guard hasFinished == false else {
            stateLock.unlock()
            return
        }
        hasFinished = true
        stateLock.unlock()

        if let error {
            continuationBox.finish(throwing: error)
        } else {
            continuationBox.finish()
        }
        Task {
            _ = try? await awaitFuture(videoStream.stopStreaming())
            clearConsumer()
        }
    }

    private func clearConsumer() {
        stateLock.lock()
        consumer = nil
        stateLock.unlock()
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation?

    func set(_ continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTerminationHandler(
        _ handler: @escaping @Sendable (AsyncThrowingStream<VideoFrame, Error>.Continuation.Termination) -> Void
    ) {
        lock.lock()
        continuation?.onTermination = handler
        lock.unlock()
    }

    func yield(_ frame: VideoFrame) {
        lock.lock()
        continuation?.yield(frame)
        lock.unlock()
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        lock.unlock()
    }
}

private final class MJPEGFrameAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let startMarker = Data([0xFF, 0xD8])
    private let endMarker = Data([0xFF, 0xD9])

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var frames: [Data] = []

        while let start = buffer.range(of: startMarker) {
            guard let end = buffer.range(
                of: endMarker,
                options: [],
                in: start.upperBound..<buffer.endIndex
            ) else {
                if start.lowerBound > 0 {
                    buffer.removeSubrange(0..<start.lowerBound)
                }
                break
            }

            let frameEnd = end.upperBound
            frames.append(buffer.subdata(in: start.lowerBound..<frameEnd))
            buffer.removeSubrange(0..<frameEnd)
        }

        if buffer.count > 4 * 1024 * 1024 {
            if let start = buffer.range(of: startMarker) {
                buffer.removeSubrange(0..<start.lowerBound)
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        return frames
    }
}
