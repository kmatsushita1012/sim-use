// SPDX-License-Identifier: Apache-2.0
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import IOSurface
import ObjectiveC

/// Captures one Simulator framebuffer without using FBVideoStream or the CLI.
///
/// This is intentionally private to SimUseKit. The existing simulator command
/// and daemon paths continue to use their original implementations.
actor SimulatorIOSurfaceCapture {
    private enum Phase {
        case stopped
        case starting
        case running
    }

    private let queue: DispatchSerialQueue
    private let deviceID: SimulatorID
    private var phase = Phase.stopped
    private var onFrame: (@Sendable (VideoFrame) -> Void)?
    private var descriptors: [NSObject] = []
    private var callbackUUIDs: [ObjectIdentifier: UUID] = [:]
    private var ioClient: NSObject?
    private var idleTimer: Task<Void, Never>?
    private var lastSeeds: [ObjectIdentifier: UInt32] = [:]
    private var rewireTickCount = 0
    private var frameCount: UInt64 = 0
    private var lastEmission: ContinuousClock.Instant?
    private var photocopier = SimulatorVideoPixelBufferCopier()
    private var configuration = VideoStreamConfiguration()

    init(deviceID: SimulatorID) {
        self.deviceID = deviceID
        self.queue = DispatchSerialQueue(
            label: "com.simusekit.video.capture.\(deviceID.rawValue)",
            qos: .userInteractive
        )
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func start(
        configuration: VideoStreamConfiguration,
        onFrame: @escaping @Sendable (VideoFrame) -> Void
    ) async throws {
        guard phase == .stopped else { return }
        phase = .starting
        self.configuration = configuration
        self.onFrame = onFrame
        self.frameCount = 0
        self.lastEmission = nil
        self.rewireTickCount = 0

        do {
            try SimulatorVideoFrameworkLoader.load()
            guard let device = Self.findSimulator(udid: deviceID.rawValue) else {
                throw SimulatorVideoCaptureError.deviceNotFound(deviceID.rawValue)
            }
            let state = device.value(forKey: "stateString") as? String ?? "unknown"
            guard state == "Booted" else {
                throw SimulatorVideoCaptureError.deviceNotBooted(deviceID.rawValue, state: state)
            }
            guard let io = device.perform(NSSelectorFromString("io"))?
                .takeUnretainedValue() as? NSObject else {
                throw SimulatorVideoCaptureError.ioUnavailable
            }
            ioClient = io
            try await wireUpFramebufferWithRetry()
            phase = .running
            startIdleTimer()
        } catch {
            phase = .stopped
            stopCallbacks(clearIO: true)
            throw error
        }
    }

    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped
        idleTimer?.cancel()
        idleTimer = nil
        stopCallbacks(clearIO: true)
        onFrame = nil
    }

    private func wireUpFramebuffer() throws {
        guard let ioClient else {
            throw SimulatorVideoCaptureError.ioUnavailable
        }

        ioClient.perform(NSSelectorFromString("updateIOPorts"))
        let candidates = try findFramebufferDescriptors(io: ioClient)
        let isSameDescriptorSet = hasSameDescriptorSet(as: candidates)
        if isSameDescriptorSet == false {
            // CoreSimulator can replace the framebuffer connection while the
            // descriptor objects remain retained by this capture actor. Their
            // callback UUIDs are no longer valid at that point, and asking the
            // private API to unregister them triggers a ROCKit assertion.
            stopCallbacks(clearIO: false, unregister: false)
        }
        descriptors = candidates
        lastSeeds.removeAll()

        if isSameDescriptorSet == false {
            for descriptor in candidates {
                try registerFrameCallbacks(descriptor: descriptor)
            }
        }

        captureFrame(force: true)
    }

    private func wireUpFramebufferWithRetry() async throws {
        let maximumAttempts = 10
        var lastError: Error?

        for attempt in 0..<maximumAttempts {
            do {
                try wireUpFramebuffer()
                return
            } catch {
                guard let captureError = error as? SimulatorVideoCaptureError,
                      captureError.isRetryableFramebufferError else {
                    throw error
                }
                lastError = error
                guard attempt + 1 < maximumAttempts else { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        throw lastError ?? SimulatorVideoCaptureError.framebufferUnavailable("retry_exhausted")
    }

    private func findFramebufferDescriptors(io: NSObject) throws -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw SimulatorVideoCaptureError.ioPortsUnavailable
        }

        let descriptorSelector = NSSelectorFromString("descriptor")
        let surfaceSelector = NSSelectorFromString("framebufferSurface")
        var candidates: [NSObject] = []

        for port in ports {
            guard port.responds(to: descriptorSelector),
                  let descriptor = port.perform(descriptorSelector)?
                      .takeUnretainedValue() as? NSObject,
                  descriptor.responds(to: surfaceSelector) else {
                continue
            }
            candidates.append(descriptor)
        }

        guard candidates.isEmpty == false else {
            throw SimulatorVideoCaptureError.framebufferUnavailable("display_descriptor_not_found")
        }
        return candidates
    }

    private func registerFrameCallbacks(descriptor: AnyObject) throws {
        let selector = #selector(SimulatorFramebufferDescriptor.registerScreenCallbacks)
        guard descriptor.responds(to: selector) else {
            throw SimulatorVideoCaptureError.frameCallbacksUnavailable
        }

        let uuid = UUID()
        callbackUUIDs[ObjectIdentifier(descriptor)] = uuid
        descriptor.registerScreenCallbacks(
            uuid: uuid,
            callbackQueue: queue,
            frameCallback: { [self] in
                assumeIsolated { $0.captureFrame(force: false) }
            },
            surfacesChangedCallback: { [self] in
                assumeIsolated { $0.captureFrame(force: true) }
            },
            propertiesChangedCallback: {}
        )
    }

    private func startIdleTimer() {
        idleTimer = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                await self.captureIdleFrame()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func captureIdleFrame() {
        guard phase == .running else { return }
        captureFrame(force: true)
        if frameCount == 0 {
            rewireTickCount += 1
            if rewireTickCount % 5 == 0 {
                try? wireUpFramebuffer()
            }
        }
    }

    private func captureFrame(force: Bool) {
        guard phase == .starting || phase == .running,
              let descriptor = pickBestDescriptor() else {
            return
        }

        let surfaceSelector = NSSelectorFromString("framebufferSurface")
        guard let surfaceObject = descriptor.perform(surfaceSelector)?
            .takeUnretainedValue() else {
            return
        }
        let surface = unsafeBitCast(surfaceObject, to: IOSurface.self)
        let key = ObjectIdentifier(descriptor)
        let seed = IOSurfaceGetSeed(surface)
        let seedChanged = lastSeeds[key] != seed
        if frameCount > 0, force == false, seedChanged == false {
            return
        }
        lastSeeds[key] = seed

        let now = ContinuousClock.now
        if let lastEmission,
           now - lastEmission < emissionInterval {
            return
        }

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return }

        var pixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer = pixelBuffer?.takeRetainedValue(),
              let copy = photocopier.copy(pixelBuffer),
              let jpegData = SimulatorVideoJPEGEncoder.encode(
                  pixelBuffer: copy,
                  scale: configuration.scale,
                  quality: configuration.quality
              ) else {
            return
        }

        lastEmission = now
        frameCount += 1
        onFrame?(VideoFrame(jpegData: jpegData))
    }

    private var emissionInterval: ContinuousClock.Duration {
        .seconds(1.0 / Double(configuration.framesPerSecond))
    }

    private func pickBestDescriptor() -> NSObject? {
        let surfaceSelector = NSSelectorFromString("framebufferSurface")
        var best: NSObject?
        var bestArea = 0
        for descriptor in descriptors {
            guard let surfaceObject = descriptor.perform(surfaceSelector)?
                .takeUnretainedValue() else {
                continue
            }
            let surface = unsafeBitCast(surfaceObject, to: IOSurface.self)
            let area = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface)
            if area > bestArea {
                best = descriptor
                bestArea = area
            }
        }
        return best
    }

    private func hasSameDescriptorSet(as candidates: [NSObject]) -> Bool {
        guard descriptors.count == candidates.count,
              callbackUUIDs.count == candidates.count else {
            return false
        }

        let currentIDs = Set(descriptors.map { ObjectIdentifier($0) })
        let candidateIDs = Set(candidates.map { ObjectIdentifier($0) })
        return currentIDs == candidateIDs
    }

    private func stopCallbacks(clearIO: Bool, unregister: Bool = true) {
        if unregister {
            let selector = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
            for descriptor in descriptors {
                guard let uuid = callbackUUIDs[ObjectIdentifier(descriptor)] else {
                    continue
                }
                if descriptor.responds(to: selector) {
                    descriptor.perform(selector, with: uuid)
                }
            }
        }
        callbackUUIDs.removeAll()
        descriptors.removeAll()
        lastSeeds.removeAll()
        if clearIO {
            ioClient = nil
        }
    }

    private static func findSimulator(udid: String) -> NSObject? {
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
            return nil
        }
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = contextClass.perform(
            contextSelector,
            with: SimulatorVideoFrameworkLoader.developerDirectory,
            with: nil
        )?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let deviceSetSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = context.perform(deviceSetSelector, with: nil)?
            .takeUnretainedValue() as? NSObject,
              let devices = deviceSet.value(forKey: "devices") as? [NSObject] else {
            return nil
        }
        return devices.first {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid
        }
    }
}

@objc private protocol SimulatorFramebufferDescriptor {
    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func registerScreenCallbacks(
        uuid: UUID,
        callbackQueue: DispatchQueue,
        frameCallback: @convention(block) @escaping () -> Void,
        surfacesChangedCallback: @convention(block) @escaping () -> Void,
        propertiesChangedCallback: @convention(block) @escaping () -> Void
    )
}

enum SimulatorVideoCaptureError: Error, LocalizedError, Sendable {
    case deviceNotFound(String)
    case deviceNotBooted(String, state: String)
    case ioUnavailable
    case ioPortsUnavailable
    case framebufferUnavailable(String)
    case frameCallbacksUnavailable

    var isRetryableFramebufferError: Bool {
        switch self {
        case .ioPortsUnavailable, .framebufferUnavailable:
            true
        case .deviceNotFound, .deviceNotBooted, .ioUnavailable, .frameCallbacksUnavailable:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .deviceNotFound(deviceID):
            "Simulator \(deviceID) was not found."
        case let .deviceNotBooted(deviceID, state):
            "Simulator \(deviceID) is not booted (state: \(state))."
        case .ioUnavailable:
            "Simulator display I/O is unavailable."
        case .ioPortsUnavailable:
            "Simulator display ports are unavailable."
        case let .framebufferUnavailable(details):
            "Simulator framebuffer display is unavailable. (\(details))"
        case .frameCallbacksUnavailable:
            "Simulator framebuffer callbacks are unavailable."
        }
    }
}

enum SimulatorVideoFrameworkLoader {
    static var developerDirectory: String {
        if let value = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           value.isEmpty == false {
            return value
        }
        if let selected = try? FileManager.default
            .destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
           !selected.isEmpty
        {
            return selected
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    static func load() throws {
        let developerDirectory = developerDirectory
        let candidates = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developerDirectory)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        for path in candidates {
            _ = dlopen(path, RTLD_NOW)
        }
        guard NSClassFromString("SimServiceContext") != nil else {
            throw SimulatorVideoCaptureError.ioUnavailable
        }
    }
}

struct SimulatorVideoPixelBufferCopier {
    private var pool: CVPixelBufferPool?
    private var dimensions: (width: Int, height: Int)?

    mutating func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceDimensions = (
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source)
        )
        if pool == nil || dimensions?.width != sourceDimensions.width || dimensions?.height != sourceDimensions.height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sourceDimensions.width,
                kCVPixelBufferHeightKey as String: sourceDimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            dimensions = sourceDimensions
        }

        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceAddress = CVPixelBufferGetBaseAddress(source),
              let destinationAddress = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }

        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let copyBytes = min(sourceStride, destinationStride)
        for row in 0..<sourceDimensions.height {
            memcpy(
                destinationAddress + row * destinationStride,
                sourceAddress + row * sourceStride,
                copyBytes
            )
        }
        return destination
    }
}
