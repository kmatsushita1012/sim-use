// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct VideoStreamConfiguration: Sendable, Equatable, Hashable {
    public let framesPerSecond: Int
    public let quality: Int
    public let scale: Double

    public init(framesPerSecond: Int = 10, quality: Int = 80, scale: Double = 1.0) {
        self.framesPerSecond = framesPerSecond
        self.quality = quality
        self.scale = scale
    }
}

/// One JPEG frame from the application-facing stream API.
public struct VideoFrame: Sendable, Equatable {
    public let jpegData: Data
    public let timestamp: Date

    public init(jpegData: Data, timestamp: Date = Date()) {
        self.jpegData = jpegData
        self.timestamp = timestamp
    }
}

public extension SimUseClient {
    /// Streams JPEG frames from one iOS Simulator without starting the CLI or
    /// using the sim-use daemon.
    ///
    /// The capture is backed by a device-scoped IOSurface session. The session
    /// is shared by callers using the same device and configuration, while
    /// each caller receives an independently cancellable async stream.
    func streamVideo(
        on deviceID: SimulatorID,
        configuration: VideoStreamConfiguration = .init()
    ) async throws -> AsyncThrowingStream<VideoFrame, Error> {
        guard !deviceID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimUseError.invalidRequest("Device ID must not be empty.")
        }
        try validate(configuration)

        return try await SimulatorVideoStreamRegistry.shared.subscribe(
            deviceID: deviceID,
            configuration: configuration
        )
    }

    private func validate(_ configuration: VideoStreamConfiguration) throws {
        guard (1...30).contains(configuration.framesPerSecond) else {
            throw SimUseError.invalidRequest("FPS must be between 1 and 30")
        }
        guard (1...100).contains(configuration.quality) else {
            throw SimUseError.invalidRequest("Quality must be between 1 and 100")
        }
        guard configuration.scale >= 0.1, configuration.scale <= 1.0 else {
            throw SimUseError.invalidRequest("Scale must be between 0.1 and 1.0")
        }
    }
}

private actor SimulatorVideoStreamRegistry {
    static let shared = SimulatorVideoStreamRegistry()

    private struct Key: Hashable {
        let deviceID: SimulatorID
        let configuration: VideoStreamConfiguration
    }

    private var sessions: [Key: SimulatorVideoStreamSession] = [:]

    func subscribe(
        deviceID: SimulatorID,
        configuration: VideoStreamConfiguration
    ) async throws -> AsyncThrowingStream<VideoFrame, Error> {
        let key = Key(deviceID: deviceID, configuration: configuration)
        let session: SimulatorVideoStreamSession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = SimulatorVideoStreamSession(
                deviceID: deviceID,
                configuration: configuration,
                onEmpty: { [weak self] in
                    await self?.remove(key: key)
                }
            )
            sessions[key] = session
        }

        do {
            return try await session.subscribe()
        } catch {
            await remove(key: key)
            throw SimUseError.map(error, deviceID: deviceID.rawValue)
        }
    }

    private func remove(key: Key) async {
        guard let session = sessions.removeValue(forKey: key) else { return }
        await session.stop()
    }
}

private actor SimulatorVideoStreamSession {
    private let capture: SimulatorIOSurfaceCapture
    private let configuration: VideoStreamConfiguration
    private let onEmpty: @Sendable () async -> Void
    private var continuations: [UUID: AsyncThrowingStream<VideoFrame, Error>.Continuation] = [:]
    private var latestFrame: VideoFrame?
    private var isStarted = false

    init(
        deviceID: SimulatorID,
        configuration: VideoStreamConfiguration,
        onEmpty: @escaping @Sendable () async -> Void
    ) {
        self.capture = SimulatorIOSurfaceCapture(deviceID: deviceID)
        self.configuration = configuration
        self.onEmpty = onEmpty
    }

    func subscribe() async throws -> AsyncThrowingStream<VideoFrame, Error> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncThrowingStream<VideoFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(subscriberID) }
        }
        continuations[subscriberID] = continuation

        if let latestFrame {
            continuation.yield(latestFrame)
        }

        do {
            if isStarted == false {
                try await capture.start(configuration: configuration) { [weak self] frame in
                    Task { await self?.publish(frame) }
                }
                isStarted = true
            }
            return stream
        } catch {
            continuations.removeValue(forKey: subscriberID)
            continuation.finish(throwing: error)
            await onEmpty()
            throw error
        }
    }

    private func publish(_ frame: VideoFrame) {
        latestFrame = frame
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }

    private func remove(_ subscriberID: UUID) async {
        continuations.removeValue(forKey: subscriberID)
        guard continuations.isEmpty else { return }
        await stop()
        await onEmpty()
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false
        await capture.stop()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}
