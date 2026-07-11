// SPDX-License-Identifier: Apache-2.0
import Darwin
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
        let result = try await client.execute(DescribeUIRequest(), on: device)
        print(result.outline)

        let session = try await client.openSession(for: device)
        try await session.send([
            .touchDown(x: 100, y: 300),
            .touchDown(x: 140, y: 300),
            .touchDown(x: 180, y: 300),
            .touchUp(x: 180, y: 300),
        ])
    }
}
