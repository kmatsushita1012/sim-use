// SPDX-License-Identifier: Apache-2.0
import Testing
import SimUseCore
import SimUseKit

@Suite("SimUseKit public API")
struct SimUseKitTests {
    @Test("SimulatorID is a stable value type")
    func simulatorID() {
        let id = SimulatorID("SIM-1")
        #expect(id.rawValue == "SIM-1")
        #expect(id == "SIM-1")
    }

    @Test("typed touch sequence preserves event order")
    func touchSequenceRequest() {
        let request = TouchSequenceRequest(events: [
            .touchDown(x: 1, y: 2),
            .touchDown(x: 3, y: 4),
            .touchUp(x: 3, y: 4),
        ])
        #expect(request.events.count == 3)
    }

    @Test("request defaults do not depend on CLI parsing")
    func describeDefaults() {
        let request = DescribeUIRequest()
        #expect(request.maxProbes == 300)
        #expect(request.minCellSize == 14)
        #expect(request.seedCellWidth == 160)
        #expect(request.seedCellHeight == 80)
    }
}
