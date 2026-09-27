// SPDX-License-Identifier: Apache-2.0
import Foundation
import CompanionUtilities
import SimUseCore
import iOSSimBackend

public struct TouchSequenceRequest: SimUseRequest {
    public typealias Output = EmptyCommandResult
    public let events: [HIDEvent]

    public init(events: [HIDEvent]) {
        self.events = events
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> EmptyCommandResult {
        try await client.send(events, on: deviceID)
        return EmptyCommandResult()
    }
}

public struct EmptyCommandResult: Codable, Equatable, Sendable {
    public init() {}
}

public struct DescribeUIRequest: SimUseRequest {
    public typealias Output = UIResult
    public let point: CoordinatePair?
    public let maxProbes: Int
    public let minCellSize: Double
    public let seedCellWidth: Double
    public let seedCellHeight: Double

    public init(
        point: CoordinatePair? = nil,
        maxProbes: Int = 300,
        minCellSize: Double = 14,
        seedCellWidth: Double = 160,
        seedCellHeight: Double = 80
    ) {
        self.point = point
        self.maxProbes = maxProbes
        self.minCellSize = minCellSize
        self.seedCellWidth = seedCellWidth
        self.seedCellHeight = seedCellHeight
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> UIResult {
        let result = try await IOSSimDescribeUICommand.performDescribeUI(
            deviceID: deviceID.rawValue,
            point: point,
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight,
            includeRaw: false
        )
        let screen = try await resolvedScreen(from: result.screen, on: deviceID, orientation: result.orientation)
        return UIResult(
            platform: result.platform,
            raw: result.raw,
            outline: result.outline,
            entries: result.entries,
            lists: result.lists,
            screen: screen,
            appLabel: result.appLabel,
            appPackage: result.appPackage,
            crashDialog: result.crashDialog,
            orientation: result.orientation,
            advisory: result.commandAdvisory
        )
    }
}

@MainActor
private func resolvedScreen(
    from reportedScreen: Outline.Frame?,
    on deviceID: SimulatorID,
    orientation: String?
) async throws -> Outline.Frame {
    if let reportedScreen, reportedScreen.width > 0, reportedScreen.height > 0 {
        return reportedScreen
    }

    // Some current Simulator runtimes expose only a zero-size AX
    // application shell while the remote-content recovery fills in visible
    // elements. The simulator's screenInfo remains authoritative for the
    // public result's coordinate canvas.
    let logger = SimUseLogger()
    let simulatorSet = try await getSimulatorSet(
        deviceSetPath: nil,
        logger: logger,
        reporter: EmptyEventReporter.shared
    )
    guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == deviceID.rawValue }),
          let native = NativePortraitSize(screenInfo: simulator.screenInfo)
    else {
        throw SimUseError.transient("Simulator UI response was missing screen geometry.")
    }
    let displayOrientation = orientation.flatMap(DisplayOrientation.init(rawValue:)) ?? .portrait
    let size = displayOrientation.uiSize(native: native)
    return Outline.Frame(
        x: 0,
        y: 0,
        width: Int(size.width.rounded()),
        height: Int(size.height.rounded())
    )
}

public struct UIResult: Codable, Equatable, Sendable {
    public let platform: String
    public let raw: JSONValue?
    public let outline: String
    public let entries: [Outline.Entry]
    public let lists: [Outline.ListSummary]
    public let screen: Outline.Frame
    public let appLabel: String
    public let appPackage: String
    public let crashDialog: CrashDialogSignal?
    public let orientation: String?
    public let advisory: CommandAdvisory?

    public init(
        platform: String,
        raw: JSONValue?,
        outline: String,
        entries: [Outline.Entry],
        lists: [Outline.ListSummary],
        screen: Outline.Frame,
        appLabel: String,
        appPackage: String,
        crashDialog: CrashDialogSignal? = nil,
        orientation: String? = nil,
        advisory: CommandAdvisory? = nil
    ) {
        self.platform = platform
        self.raw = raw
        self.outline = outline
        self.entries = entries
        self.lists = lists
        self.screen = screen
        self.appLabel = appLabel
        self.appPackage = appPackage
        self.crashDialog = crashDialog
        self.orientation = orientation
        self.advisory = advisory
    }
}

public struct TapRequest: SimUseRequest {
    public typealias Output = TapResult
    public let alias: String?
    public let point: CoordinatePair?
    public let x: Double?
    public let y: Double?
    public let accessibilityIdentifier: String?
    public let label: String?
    public let value: String?
    public let labelContains: String?
    public let labelRegex: String?
    public let elementType: String?
    public let frameSpecs: [String]
    public let preDelay: Double?
    public let postDelay: Double?
    public let duration: Double?
    public let waitTimeout: Double
    public let pollInterval: Double

    public init(
        alias: String? = nil,
        point: CoordinatePair? = nil,
        x: Double? = nil,
        y: Double? = nil,
        accessibilityIdentifier: String? = nil,
        label: String? = nil,
        value: String? = nil,
        labelContains: String? = nil,
        labelRegex: String? = nil,
        elementType: String? = nil,
        frameSpecs: [String] = [],
        preDelay: Double? = nil,
        postDelay: Double? = nil,
        duration: Double? = nil,
        waitTimeout: Double = 0,
        pollInterval: Double = 0.25
    ) {
        self.alias = alias
        self.point = point
        self.x = x
        self.y = y
        self.accessibilityIdentifier = accessibilityIdentifier
        self.label = label
        self.value = value
        self.labelContains = labelContains
        self.labelRegex = labelRegex
        self.elementType = elementType
        self.frameSpecs = frameSpecs
        self.preDelay = preDelay
        self.postDelay = postDelay
        self.duration = duration
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> TapResult {
        let targeting = TapTargetingOptions(
            pointX: x,
            pointY: y,
            point: point,
            elementID: accessibilityIdentifier,
            elementLabel: label,
            elementValue: value,
            labelContains: labelContains,
            labelRegex: labelRegex,
            elementType: elementType,
            frameSpecs: frameSpecs
        )
        let timing = TapTimingOptions(
            preDelay: preDelay,
            postDelay: postDelay,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval
        )
        let multiTouch = MultiTouchOptions(fingers: 1, fingerDistance: 50)
        try targeting.validate(alias: alias)
        try timing.validate()
        try TapTimingOptions.validateDuration(duration)
        try multiTouch.validate()
        let result = try await IOSSimTapCommand.performTap(
            alias: alias,
            targeting: targeting,
            timing: timing,
            duration: duration,
            multiTouch: multiTouch,
            device: DeviceOptions(device: deviceID.rawValue, resolved: deviceID.rawValue),
            json: JSONOutputOptions(enabled: false)
        )
        guard let x = result.x, let y = result.y else {
            throw SimUseError.transient("Simulator tap response was missing dispatch coordinates.")
        }
        return TapResult(x: x, y: y, advisory: result.commandAdvisory)
    }
}

public struct TapResult: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let advisory: CommandAdvisory?

    public init(x: Double, y: Double, advisory: CommandAdvisory? = nil) {
        self.x = x
        self.y = y
        self.advisory = advisory
    }
}

public struct SwipeRequest: SimUseRequest {
    public typealias Output = SwipeResult
    public let coordinates: SwipeCoordinates
    public let duration: Double?
    public let delta: Double?
    public let preDelay: Double?
    public let postDelay: Double?

    public init(
        coordinates: SwipeCoordinates,
        duration: Double? = nil,
        delta: Double? = nil,
        preDelay: Double? = nil,
        postDelay: Double? = nil
    ) {
        self.coordinates = coordinates
        self.duration = duration
        self.delta = delta
        self.preDelay = preDelay
        self.postDelay = postDelay
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> SwipeResult {
        var command = IOSSimSwipeCommand()
        command.coordinates = SwipeCoordinateOptions(
            startX: coordinates.startX,
            startY: coordinates.startY,
            endX: coordinates.endX,
            endY: coordinates.endY
        )
        command.coordinateSpace = .native
        command.duration = duration
        command.delta = delta
        command.preDelay = preDelay
        command.postDelay = postDelay
        command.device = DeviceOptions(device: deviceID.rawValue, resolved: deviceID.rawValue)
        command.json = JSONOutputOptions(enabled: false)
        try command.validate()
        let result = try await command.execute()
        return SwipeResult(coordinates: result.coordinates)
    }
}

public struct SwipeResult: Codable, Equatable, Sendable {
    public let coordinates: SwipeCoordinates

    public init(coordinates: SwipeCoordinates) {
        self.coordinates = coordinates
    }
}

/// Application-facing typed request for iOS gesture presets. The backend's
/// `IOSSimGestureCommand.ExecutionResult` is intentionally not part of this
/// API; callers receive `GestureResult` instead.
public struct GestureRequest: SimUseRequest {
    public typealias Output = GestureResult

    public let preset: GesturePreset
    public let screenWidth: Double?
    public let screenHeight: Double?
    public let duration: Double?
    public let delta: Double?
    public let scale: Double?
    public let angle: Double?
    public let centerX: Double?
    public let centerY: Double?
    public let radius: Double?
    public let steps: Int
    public let stepMs: Int?
    public let preDelay: Double?
    public let postDelay: Double?

    public init(
        preset: GesturePreset,
        screenWidth: Double? = nil,
        screenHeight: Double? = nil,
        duration: Double? = nil,
        delta: Double? = nil,
        scale: Double? = nil,
        angle: Double? = nil,
        centerX: Double? = nil,
        centerY: Double? = nil,
        radius: Double? = nil,
        steps: Int = 10,
        stepMs: Int? = nil,
        preDelay: Double? = nil,
        postDelay: Double? = nil
    ) {
        self.preset = preset
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.duration = duration
        self.delta = delta
        self.scale = scale
        self.angle = angle
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.steps = steps
        self.stepMs = stepMs
        self.preDelay = preDelay
        self.postDelay = postDelay
    }

    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> GestureResult {
        var command = IOSSimGestureCommand()
        command.preset = preset
        command.screenWidth = screenWidth
        command.screenHeight = screenHeight
        command.duration = duration
        command.delta = delta
        command.scale = scale
        command.angle = angle
        command.centerX = centerX
        command.centerY = centerY
        command.radius = radius
        command.steps = steps
        command.stepMs = stepMs
        command.preDelay = preDelay
        command.postDelay = postDelay
        command.device = DeviceOptions(device: deviceID.rawValue, resolved: deviceID.rawValue)
        command.json = JSONOutputOptions(enabled: false)
        try command.validate()
        _ = try await command.execute()
        return GestureResult()
    }
}

public struct GestureResult: Codable, Equatable, Sendable {
    public init() {}
}
