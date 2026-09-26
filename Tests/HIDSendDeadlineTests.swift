// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// `HIDSendDeadline` turns a dead-port hang (a perform whose completion
// never fires) into a loud, classifiable error. The race mechanics and
// the recovery-classification invariant are tested here without FB*
// types.

@Suite("HIDSendDeadline")
struct HIDSendDeadlineTests {

    private struct TimeoutMarker: Error {}

    @Test("A fast operation wins the race and returns its value")
    func fastOperationReturnsValue() async throws {
        let value = try await HIDSendDeadline.run(milliseconds: 5_000) {
            42
        } onTimeout: {
            TimeoutMarker()
        }
        #expect(value == 42)
    }

    @Test("An overflowing millisecond value saturates instead of trapping")
    func hugeTimeoutSaturates() async throws {
        // Any parseable SIM_USE_HID_SEND_TIMEOUT_MS reaches the ms→ns
        // multiply; UInt64.max used to trap at runtime. It must behave
        // as "effectively no deadline" instead.
        let value = try await HIDSendDeadline.run(milliseconds: .max) {
            7
        } onTimeout: {
            TimeoutMarker()
        }
        #expect(value == 7)
    }

    @Test("A fast operation's error propagates unchanged")
    func fastOperationErrorPropagates() async {
        struct PerformFailure: Error {}
        await #expect(throws: PerformFailure.self) {
            try await HIDSendDeadline.run(milliseconds: 5_000) { () -> Int in
                throw PerformFailure()
            } onTimeout: {
                TimeoutMarker()
            }
        }
    }

    @Test("A hanging operation times out and its task is cancelled")
    func slowOperationThrowsTimeoutAndCancels() async throws {
        let cancelled = CancellationProbe()
        await #expect(throws: TimeoutMarker.self) {
            try await HIDSendDeadline.run(milliseconds: 50) { () -> Int in
                // Stand-in for a send into a dead mach port: never
                // completes on its own, only responds to cancellation.
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    await cancelled.mark()
                    throw error
                }
                return 0
            } onTimeout: {
                TimeoutMarker()
            }
        }
        // Losing the race must cancel the operation's task — that is
        // what FutureBridge.value forwards to FBFuture.cancel().
        await Task.yield()
        #expect(await cancelled.wasMarked())
    }

    @Test("The timeout fires even when the operation ignores cancellation", .timeLimit(.minutes(1)))
    func timeoutFiresWhenOperationIgnoresCancellation() async {
        // Faithful stand-in for the upstream send paths
        // (FBSimulatorIndigoHIDClient.send / FBSimulatorDTUHIDTransport
        // .send): the continuation is parked — retained but unresumed,
        // observing no cancellation — the way a dead port's pending
        // completion callback holds it. A task-group deadline waits
        // behind this zombie forever; the unstructured race must
        // abandon it and still deliver the timeout error.
        let gate = ContinuationGate()
        let zombie = ZombieTracker()
        await #expect(throws: TimeoutMarker.self) {
            try await HIDSendDeadline.run(milliseconds: 100) { () -> Int in
                let value = try await withCheckedThrowingContinuation { continuation in
                    gate.park(continuation)
                }
                await zombie.markFinished()
                return value
            } onTimeout: {
                TimeoutMarker()
            }
        }
        // Deterministic teardown: release the parked continuation and
        // wait for the abandoned task to run out, so the test leaves no
        // suspended task behind and no unresumed CheckedContinuation to
        // log a "leaked its continuation" runtime diagnostic.
        gate.release(returning: 0)
        await zombie.waitUntilFinished()
    }

    @Test("Outer cancellation is not blocked by a cancellation-deaf operation", .timeLimit(.minutes(1)))
    func outerCancellationResumesPromptly() async {
        let gate = ContinuationGate()
        let zombie = ZombieTracker()
        let caller = Task { () -> Bool in
            do {
                _ = try await HIDSendDeadline.run(milliseconds: 60_000) { () -> Int in
                    let value = try await withCheckedThrowingContinuation { continuation in
                        gate.park(continuation)
                    }
                    await zombie.markFinished()
                    return value
                } onTimeout: {
                    TimeoutMarker()
                }
                return false
            } catch {
                return error is CancellationError
            }
        }
        // Let the race start, then cancel the caller — it must resume
        // with CancellationError long before the 60 s deadline.
        try? await Task.sleep(nanoseconds: 100_000_000)
        caller.cancel()
        #expect(await caller.value)
        // Same deterministic teardown as above.
        gate.release(returning: 0)
        await zombie.waitUntilFinished()
    }

    /// Parks a continuation the way a dead port's pending completion
    /// callback would: retained, unresumed, deaf to cancellation —
    /// until the test releases it explicitly.
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var parked: CheckedContinuation<Int, Error>?

        func park(_ continuation: CheckedContinuation<Int, Error>) {
            lock.lock()
            parked = continuation
            lock.unlock()
        }

        func release(returning value: Int) {
            lock.lock()
            let continuation = parked
            parked = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    /// Lets the test await the abandoned task's completion after the
    /// gate opens (the race itself exposes no handle to it, by design).
    private actor ZombieTracker {
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markFinished() {
            finished = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func waitUntilFinished() async {
            if finished { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @Test("The production timeout message classifies as invalidateOnly")
    func timeoutMessageIsNotClassifiedAsDeadTransport() {
        // A timed-out composite may have delivered some sub-events, so
        // recovery must never blind-retry it. Pin the wording used in
        // HIDInteractor.performHIDEventOnce against the dead-transport
        // markers that would trigger invalidateAndRetry.
        let message = """
        HID event delivery timed out after 30000 ms; the connection to \
        simulator 87FDA16F-2071-4646-AC69-F09063049E78 may be dead (rebooted \
        mid-command?). The cached connection is dropped and rebuilt on the \
        next command.
        """
        #expect(HIDPerformRecovery.classify(message: message) == .invalidateOnly)
    }

    private actor CancellationProbe {
        private var marked = false
        func mark() { marked = true }
        func wasMarked() -> Bool { marked }
    }
}
