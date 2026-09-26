// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded wait for a HID send.
///
/// A send through a dead HID mach port can hang forever on current
/// SimulatorKit (observed live on Xcode 26.5 / iOS 26.2): the perform's
/// completion never fires, no error reaches
/// `HIDPerformRecovery.classify`, and the daemon wedges mid-request
/// until it is killed. The boot-identity gate prevents that for reboots
/// that happen *between* commands; this deadline covers the residual
/// window — a reboot mid-command, or a boot-identity signal failing in
/// a way not yet seen — by turning the hang into a loud error.
///
/// The timeout error's text must match none of
/// `HIDPerformRecovery.deadTransportMarkers` (pinned by a unit test):
/// a timed-out composite may have delivered some sub-events, so
/// recovery must stay `invalidateOnly` — fail the command, rebuild on
/// the next one — never a blind retry.
enum HIDSendDeadline {

    /// Races `operation` against a deadline. The deadline fires even
    /// when the operation ignores cancellation.
    ///
    /// Deliberately an UNSTRUCTURED race, not a task group: the upstream
    /// HID send paths suspend on bare continuations that only their
    /// mach / XPC completion callbacks resume
    /// (`FBSimulatorIndigoHIDClient.send`,
    /// `FBSimulatorDTUHIDTransport.send` — neither installs a
    /// cancellation handler), so a send into a dead port never finishes,
    /// cancelled or not. A task group awaits all children before
    /// returning, which would park the timeout error behind that zombie
    /// child forever. Here the loser is cancelled (a cooperative
    /// operation still stops early) and then abandoned: the caller gets
    /// its result at the deadline regardless, at the cost of one
    /// suspended task per dead send — bounded by how often a simulator
    /// dies mid-command, and equivalent to the pre-migration FBFuture
    /// bridge, whose cancel resolved the wrapper future while the
    /// underlying mach send kept dangling.
    static func run<T: Sendable>(
        milliseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout makeTimeoutError: @escaping @Sendable () -> Error
    ) async throws -> T {
        // Saturate instead of trapping on the ms→ns conversion: any
        // parseable SIM_USE_HID_SEND_TIMEOUT_MS reaches this multiply,
        // and an absurdly large value means "effectively no deadline"
        // (UInt64.max ns ≈ 584 years), not a crash.
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    deadlineNanos: overflow ? .max : nanoseconds,
                    operation: operation,
                    makeTimeoutError: makeTimeoutError
                )
            }
        } onCancel: {
            race.cancelFromOutside()
        }
    }

    /// First-resume-wins rendezvous between the operation task, the
    /// deadline timer, and outer cancellation. `@unchecked Sendable`:
    /// all mutable state is guarded by `lock`.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var operationTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?
        private var cancelledBeforeStart = false

        func start(
            continuation: CheckedContinuation<T, Error>,
            deadlineNanos: UInt64,
            operation: @escaping @Sendable () async throws -> T,
            makeTimeoutError: @escaping @Sendable () -> Error
        ) {
            lock.lock()
            self.continuation = continuation
            let cancelled = cancelledBeforeStart
            lock.unlock()
            // The outer task was cancelled before the race could start
            // (withTaskCancellationHandler fires onCancel immediately for
            // an already-cancelled task): resume without spawning anything.
            if cancelled {
                finish(with: .failure(CancellationError()))
                return
            }

            let operationTask = Task {
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                self.finish(with: result)
            }
            let timerTask = Task {
                try? await Task.sleep(nanoseconds: deadlineNanos)
                // A cancelled timer lost the race; the winner already
                // resumed the caller.
                guard !Task.isCancelled else { return }
                self.finish(with: .failure(makeTimeoutError()))
            }

            lock.lock()
            if self.continuation == nil {
                // A child finished before the tasks could be stored;
                // finish() couldn't cancel them, so do it here.
                lock.unlock()
                operationTask.cancel()
                timerTask.cancel()
            } else {
                self.operationTask = operationTask
                self.timerTask = timerTask
                lock.unlock()
            }
        }

        /// Resumes the caller exactly once and cancels the loser.
        private func finish(with result: Result<T, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let operationTask = self.operationTask
            let timerTask = self.timerTask
            self.operationTask = nil
            self.timerTask = nil
            lock.unlock()

            guard let continuation else { return }
            operationTask?.cancel()
            timerTask?.cancel()
            continuation.resume(with: result)
        }

        func cancelFromOutside() {
            lock.lock()
            guard continuation != nil else {
                // Not started yet (or already finished); flag it so
                // start() resumes immediately instead of racing.
                cancelledBeforeStart = true
                lock.unlock()
                return
            }
            lock.unlock()
            finish(with: .failure(CancellationError()))
        }
    }
}
