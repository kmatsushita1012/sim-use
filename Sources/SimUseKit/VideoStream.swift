// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import CoreGraphics
import FBSimulatorControl
@preconcurrency import FBControlCore
import ImageIO
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
    /// The stream is backed by FBSimulatorControl's BGRA video stream. JPEG
    /// encoding happens in this API after receiving raw frames, because the
    /// Simulator runtime does not support the FBVideoStream MJPEG codec on
    /// every Xcode/runtime combination.
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

            guard let screenInfo = simulator.screenInfo,
                  screenInfo.widthPixels > 0,
                  screenInfo.heightPixels > 0 else {
                throw SimUseError.invalidRequest("Simulator screen size is unavailable.")
            }
            let pixelWidth = max(Int((Double(screenInfo.widthPixels) * configuration.scale).rounded()), 1)
            let pixelHeight = max(Int((Double(screenInfo.heightPixels) * configuration.scale).rounded()), 1)
            let streamConfiguration = FBVideoStreamConfiguration(
                encoding: .BGRA,
                framesPerSecond: NSNumber(value: configuration.framesPerSecond),
                compressionQuality: NSNumber(value: Double(configuration.quality) / 100.0),
                scaleFactor: NSNumber(value: configuration.scale),
                avgBitrate: nil,
                keyFrameRate: nil
            )
            let videoStream = try await awaitFutureValue(
                simulator.createStream(with: streamConfiguration)
            )
            let bridge = BGRAVideoStreamBridge(
                videoStream: videoStream,
                deviceID: deviceID
            )
            bridge.configureFrameSize(width: pixelWidth, height: pixelHeight, quality: configuration.quality)
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
                    continuation.resume(throwing: VideoStreamError.futureResolvedWithoutResult)
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

private enum VideoStreamError: Error {
    case futureResolvedWithoutResult
    case invalidFrameSize
}

private final class BGRAVideoStreamBridge: @unchecked Sendable {
    let frames: AsyncThrowingStream<VideoFrame, Error>

    private let videoStream: any FBVideoStream
    private let deviceID: SimulatorID
    private let continuationBox: ContinuationBox
    private let assembler = BGRAVideoFrameAssembler()
    private let stateLock = NSLock()
    private var consumer: (any FBDataConsumer)?
    private var hasFinished = false
    private var frameWidth = 0
    private var frameHeight = 0
    private var quality = 80

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

    func configureFrameSize(width: Int, height: Int, quality: Int) {
        stateLock.lock()
        frameWidth = width
        frameHeight = height
        self.quality = quality
        stateLock.unlock()
        assembler.configure(frameWidth: width, frameHeight: height)
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
        let frames = assembler.append(data)
        stateLock.lock()
        let width = frameWidth
        let height = frameHeight
        let quality = self.quality
        stateLock.unlock()
        guard width > 0, height > 0 else { return }

        for bgraData in frames {
            guard let jpegData = Self.encodeJPEG(
                fromBGRA: bgraData,
                width: width,
                height: height,
                quality: quality
            ) else {
                finish(throwing: VideoStreamError.invalidFrameSize)
                return
            }
            continuationBox.yield(VideoFrame(jpegData: jpegData))
        }
    }

    private static func encodeJPEG(fromBGRA data: Data, width: Int, height: Int, quality: Int) -> Data? {
        let bytesPerRow = width * 4
        guard data.count == bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
                          CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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

private final class BGRAVideoFrameAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var frameByteCount = 0

    func configure(frameWidth: Int, frameHeight: Int) {
        lock.lock()
        frameByteCount = frameWidth * frameHeight * 4
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var frames: [Data] = []

        guard frameByteCount > 0 else { return frames }
        while buffer.count >= frameByteCount {
            frames.append(buffer.subdata(in: 0..<frameByteCount))
            buffer.removeSubrange(0..<frameByteCount)
        }

        if buffer.count > frameByteCount * 2 {
            buffer.removeAll(keepingCapacity: true)
        }

        return frames
    }
}
