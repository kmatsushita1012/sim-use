// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// A long-running `adb` child process whose stdout is delivered
/// incrementally as raw binary chunks — the streaming counterpart to
/// `Adb.run`, which buffers all output into a `String` and only returns
/// after exit. Used to pipe `adb exec-out screenrecord --output-format=h264`
/// straight into the H.264 muxer.
///
/// Follows the same drain / termination-semaphore patterns as `Adb.run`
/// (readabilityHandler to avoid the 64 KB pipe deadlock, exit-driven wakeup,
/// ENOENT → `BridgeError.adbMissing`).
public final class AdbStreamingProcess: Sendable {
    /// The non-Sendable subprocess objects plus the byte tallies, confined
    /// to the lock.
    private struct State {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var stdoutByteCount: Int64 = 0
        var stderrBuffer = Data()
        var stdoutClosing = false
        var activeStdoutDeliveries = 0
    }

    private let adbPath: String
    private let arguments: [String]
    private let onStdout: @Sendable (Data) -> Void
    private let onStderr: (@Sendable (String) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private let stdoutDrainedSemaphore = DispatchSemaphore(value: 0)

    public init(
        adbPath: String,
        arguments: [String],
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) {
        self.adbPath = adbPath
        self.arguments = arguments
        self.onStdout = onStdout
        self.onStderr = onStderr
    }

    public func start() throws {
        let resolvedPath = Adb.resolveOnPATH(adbPath) ?? adbPath
        try state.withLock { state in
            state.process.executableURL = URL(fileURLWithPath: resolvedPath)
            state.process.arguments = arguments
            state.process.standardOutput = state.stdoutPipe
            state.process.standardError = state.stderrPipe

            state.stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self, self.beginStdoutDelivery() else { return }
                defer { self.endStdoutDelivery() }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                self.state.withLock { $0.stdoutByteCount += Int64(chunk.count) }
                self.onStdout(chunk)
            }
            state.stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self, !chunk.isEmpty else { return }
                self.state.withLock { $0.stderrBuffer.append(chunk) }
            }
            state.process.terminationHandler = { [exitSemaphore] _ in exitSemaphore.signal() }

            do {
                try state.process.run()
            } catch {
                let nsErr = error as NSError
                let isMissing =
                    (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) ||
                    (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENOENT))
                if isMissing {
                    throw BridgeError.adbMissing
                }
                throw BridgeError.transport(underlying: "Failed to spawn adb: \(error.localizedDescription)", serial: nil)
            }
        }
    }

    /// Send SIGINT — `screenrecord`'s clean-stop signal (flushes the encoder
    /// and finalizes its output before exiting).
    public func interrupt() {
        state.withLock { state in
            if state.process.isRunning { kill(state.process.processIdentifier, SIGINT) }
        }
    }

    public func terminate() {
        state.withLock { state in
            if state.process.isRunning { state.process.terminate() }
        }
    }

    public var isRunning: Bool { state.withLock { $0.process.isRunning } }

    public var stdoutByteCount: Int64 { state.withLock { $0.stdoutByteCount } }

    public var collectedStderr: String {
        state.withLock { String(data: $0.stderrBuffer, encoding: .utf8) ?? "" }
    }

    /// Block until the child exits (or `timeout` elapses), then detach the
    /// handlers and drain any residual stdout. Returns the exit status, or
    /// nil on timeout (after a SIGTERM escalation).
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Int32? {
        let timedOut = exitSemaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            state.withLock { if $0.process.isRunning { $0.process.terminate() } }
            _ = exitSemaphore.wait(timeout: .now() + 0.5)
        }

        let waitForStdoutDeliveries = state.withLock { state in
            state.stdoutClosing = true
            state.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            state.stderrPipe.fileHandleForReading.readabilityHandler = nil
            return state.activeStdoutDeliveries > 0
        }
        if waitForStdoutDeliveries {
            stdoutDrainedSemaphore.wait()
        }

        let (residualOut, status): (Data, Int32) = state.withLock { state in
            let residual = state.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let residualErr = state.stderrPipe.fileHandleForReading.readDataToEndOfFile()
            state.stdoutByteCount += Int64(residual.count)
            state.stderrBuffer.append(residualErr)
            return (residual, state.process.terminationStatus)
        }

        if !residualOut.isEmpty { onStdout(residualOut) }
        if let onStderr {
            let stderr = collectedStderr
            if !stderr.isEmpty { onStderr(stderr) }
        }

        return timedOut ? nil : status
    }

    private func beginStdoutDelivery() -> Bool {
        state.withLock { state in
            guard !state.stdoutClosing else { return false }
            state.activeStdoutDeliveries += 1
            return true
        }
    }

    private func endStdoutDelivery() {
        let shouldSignal = state.withLock { state in
            state.activeStdoutDeliveries -= 1
            return state.stdoutClosing && state.activeStdoutDeliveries == 0
        }
        if shouldSignal {
            stdoutDrainedSemaphore.signal()
        }
    }
}
