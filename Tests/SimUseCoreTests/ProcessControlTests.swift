// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import SimUseCore

/// Pins the process-control primitives the streaming/recording commands
/// hang their stop paths on.
@Suite("ProcessControl primitives")
struct ProcessControlTests {
    @Test("OnceFlag fires exactly once across concurrent setters")
    func onceFlagSingleWinner() async {
        let flag = OnceFlag()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<32 {
                group.addTask { flag.trySet() }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(winners == 1)
        #expect(flag.trySet() == false)
    }

    @Test("cancellableSleep wakes early when the flag is cancelled")
    func cancellableSleepEarlyWake() async throws {
        let flag = CancellationFlag()
        let start = ContinuousClock.now

        let sleeper = Task {
            try await cancellableSleep(seconds: 30, flag: flag)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        flag.cancel()
        try await sleeper.value

        // A full 30 s sleep would dwarf this bound; the 5 ms polling
        // chunks mean cancellation lands within tens of milliseconds.
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5), "cancelled sleep took \(elapsed)")
    }

    @Test("cancellableSleep returns immediately for non-positive durations")
    func cancellableSleepZero() async throws {
        let flag = CancellationFlag()
        try await cancellableSleep(seconds: 0, flag: flag)
        try await cancellableSleep(seconds: -1, flag: flag)
    }

    @Test("CancellationFlag is sticky")
    func cancellationFlagSticky() {
        let flag = CancellationFlag()
        #expect(!flag.isCancelled())
        flag.cancel()
        flag.cancel()
        #expect(flag.isCancelled())
    }
}
