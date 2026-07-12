// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SimUseCore
import SimUseKit

@main
@MainActor
struct SimUseMacOSClient {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: SimUseMacOSClient <simulator-udid>\n", stderr)
            return
        }

        let device = SimulatorID(CommandLine.arguments[1])
        let client = SimUseClient()

        if CommandLine.arguments.contains("--benchmark-touch") {
            try await benchmarkTouch(device: device, client: client)
            return
        }

        let result = try await client.execute(DescribeUIRequest(), on: device)
        print(result.outline)

        if CommandLine.arguments.contains("--describe-only") {
            return
        }

        let session = try await client.openSession(for: device)
        try await session.send([
            .touchDown(x: 100, y: 300),
            .touchMove(x: 140, y: 300),
            .touchMove(x: 180, y: 300),
            .touchUp(x: 180, y: 300),
        ])
    }

    private static func benchmarkTouch(device: SimulatorID, client: SimUseClient) async throws {
        let sessionStart = Date.timeIntervalSinceReferenceDate
        let session = try await client.openSession(for: device)
        let sessionSetup = Date.timeIntervalSinceReferenceDate - sessionStart
        let events: [HIDEvent] = [
            .touchDown(x: 100, y: 500),
            .touchDown(x: 100, y: 450),
            .touchDown(x: 100, y: 400),
            .touchUp(x: 100, y: 400),
        ]

        let continuousStart = Date.timeIntervalSinceReferenceDate
        let timings = try await session.sendTimed(events)
        let continuousTotal = Date.timeIntervalSinceReferenceDate - continuousStart

        print("continuous_touch session_setup=\(format(sessionSetup))s total=\(format(continuousTotal))s")
        for timing in timings {
            print("event[\(timing.index)] \(eventName(timing.event)) interval=\(format(timing.interval))s elapsed=\(format(timing.elapsed))s")
        }

        // Keep this comparison on the same direct HID path. Calling the
        // parser-backed SwipeRequest here would reintroduce CLI command
        // initialization into the application-facing benchmark.
        let swipeTimings = try await session.sendTimed([
            .swipe(
                startX: 100,
                startY: 500,
                endX: 100,
                endY: 400,
                delta: 0.05,
                duration: 0.2
            ),
        ])
        let swipeTotal = swipeTimings.last?.elapsed ?? 0
        print("swipe total=\(format(swipeTotal))s")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.6f", seconds)
    }

    private static func eventName(_ event: HIDEvent) -> String {
        switch event {
        case .touchDown: return "touchDown"
        case .touchMove: return "touchMove(touchDownAt)"
        case .touchUp: return "touchUp"
        case .tap: return "tap"
        case .swipe: return "swipe"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .buttonDown: return "buttonDown"
        case .buttonUp: return "buttonUp"
        case .delay: return "delay"
        }
    }
}
