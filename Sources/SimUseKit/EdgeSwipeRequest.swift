// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Direction of a system edge swipe. This is intentionally separate from
/// `GesturePreset`: edge swipes must be emitted as one continuous touch
/// sequence rather than as the backend's ordinary swipe event.
public enum EdgeSwipeDirection: String, Sendable {
    case leading
    case trailing
    case top
    case bottom
}

/// Sends a continuous touch sequence that starts at a display edge.
public struct EdgeSwipeRequest: SimUseRequest {
    public typealias Output = EmptyCommandResult

    public let direction: EdgeSwipeDirection
    public let screenWidth: Double
    public let screenHeight: Double
    public let duration: TimeInterval
    public let steps: Int

    public init(
        direction: EdgeSwipeDirection,
        screenWidth: Double,
        screenHeight: Double,
        duration: TimeInterval = 0.3,
        steps: Int = 10
    ) {
        self.direction = direction
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.duration = duration
        self.steps = steps
    }

    public func execute(
        on deviceID: SimulatorID,
        using client: SimUseClient
    ) async throws -> EmptyCommandResult {
        let points = trajectory()
        let interval = duration / Double(points.count - 1)
        var events: [HIDEvent] = [.touchDown(x: points[0].x, y: points[0].y)]
        events.reserveCapacity(points.count * 2)

        for point in points.dropFirst().dropLast() {
            events.append(.delay(interval))
            events.append(.touchMove(x: point.x, y: point.y))
        }

        events.append(.delay(interval))
        let end = points[points.count - 1]
        events.append(.touchUp(x: end.x, y: end.y))
        try await client.send(events, on: deviceID)
        return EmptyCommandResult()
    }

    private func trajectory() -> [(x: Double, y: Double)] {
        let edgeInset = 1.0
        let targetRatio = 0.55
        let start: (x: Double, y: Double)
        let end: (x: Double, y: Double)

        switch direction {
        case .leading:
            start = (edgeInset, screenHeight / 2)
            end = (screenWidth * targetRatio, screenHeight / 2)
        case .trailing:
            start = (screenWidth - edgeInset, screenHeight / 2)
            end = (screenWidth * (1 - targetRatio), screenHeight / 2)
        case .top:
            start = (screenWidth / 2, edgeInset)
            end = (screenWidth / 2, screenHeight * targetRatio)
        case .bottom:
            start = (screenWidth / 2, screenHeight - edgeInset)
            end = (screenWidth / 2, screenHeight * (1 - targetRatio))
        }

        let count = max(2, steps + 1)
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            return (
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        }
    }
}
