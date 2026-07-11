// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import iOSSimBackend

public struct TouchSequenceRequest: SimUseRequest {
    public typealias Output = EmptyCommandResult
    public let events: [HIDEvent]

    public init(events: [HIDEvent]) {
        self.events = events
    }

    @MainActor
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

    @MainActor
    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> UIResult {
        var command = IOSSimDescribeUICommand()
        command.point = point
        command.maxProbes = maxProbes
        command.minCellSize = minCellSize
        command.seedCellWidth = seedCellWidth
        command.seedCellHeight = seedCellHeight
        command.device.device = deviceID.rawValue
        try command.resolveDeferredArguments()
        try command.validate()
        let result = try await command.execute()
        return UIResult(
            platform: result.platform,
            raw: result.raw,
            outline: result.outline,
            entries: result.entries,
            lists: result.lists,
            screen: result.screen,
            appLabel: result.appLabel,
            appPackage: result.appPackage,
            crashDialog: result.crashDialog,
            orientation: result.orientation,
            advisory: result.commandAdvisory
        )
    }
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

    @MainActor
    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> TapResult {
        var command = IOSSimTapCommand()
        command.alias = alias
        command.point = point
        command.pointX = x
        command.pointY = y
        command.elementID = accessibilityIdentifier
        command.elementLabel = label
        command.elementValue = value
        command.labelContains = labelContains
        command.labelRegex = labelRegex
        command.elementType = elementType
        command.frameSpecs = frameSpecs
        command.preDelay = preDelay
        command.postDelay = postDelay
        command.duration = duration
        command.waitTimeout = waitTimeout
        command.pollInterval = pollInterval
        command.device.device = deviceID.rawValue
        try command.resolveDeferredArguments()
        try command.validate()
        let result = try await command.execute()
        return TapResult(x: result.x, y: result.y, advisory: result.commandAdvisory)
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

    @MainActor
    public func execute(on deviceID: SimulatorID, using client: SimUseClient) async throws -> SwipeResult {
        var command = IOSSimSwipeCommand()
        command.coordinates.startX = coordinates.startX
        command.coordinates.startY = coordinates.startY
        command.coordinates.endX = coordinates.endX
        command.coordinates.endY = coordinates.endY
        command.duration = duration
        command.delta = delta
        command.preDelay = preDelay
        command.postDelay = postDelay
        command.device.device = deviceID.rawValue
        try command.resolveDeferredArguments()
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
