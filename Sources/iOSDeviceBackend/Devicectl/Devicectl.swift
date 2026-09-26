// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shells out to `xcrun devicectl` (CoreDevice) for capabilities the
/// accessibility audit channel does not offer — currently screen capture.
///
/// Unlike the audit channel, CoreDevice capture is not limited to
/// development-signed foreground apps: it captures whatever is on screen,
/// including SpringBoard and system apps. Device *selection* still goes
/// through `DeviceSession.resolveDevice` so every `ios-device` verb sees the
/// same device set and errors; only the capture itself runs over CoreDevice.
enum Devicectl {
    struct Failure: Error, LocalizedError, CustomStringConvertible {
        let message: String
        var errorDescription: String? { message }
        var description: String { message }
    }

    /// Argument vector for a screenshot capture, separated from the spawn so
    /// tests can pin the invocation without a device. `--quiet` suppresses
    /// devicectl's own progress output; the verb prints its own confirmation.
    static func screenshotArguments(deviceIdentifier: String, destination: URL) -> [String] {
        [
            "devicectl", "device", "capture", "screenshot",
            "--device", deviceIdentifier,
            "--destination", destination.path,
            "--timeout", "30",
            "--quiet",
        ]
    }

    /// Runs devicectl and fails with its stderr on a non-zero exit.
    /// `executablePath` is injectable so tests can drive the drain and error
    /// mapping against `/bin/sh`; production uses the default `xcrun`.
    static func run(arguments: [String], executablePath: String = "/usr/bin/xcrun") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes while the child runs so a chatty error path cannot
        // fill the ~64 KB pipe buffer and deadlock `waitUntilExit()`. Same
        // drain as `SimctlDeviceLister.runSimctl` and `Adb.run`.
        let bufferLock = NSLock()
        var errBuffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); errBuffer.append(chunk); bufferLock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw Failure(message: "could not spawn xcrun devicectl: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        bufferLock.lock()
        errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        bufferLock.unlock()

        guard process.terminationStatus == 0 else {
            let err = (String(data: errBuffer, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "xcrun devicectl exited \(process.terminationStatus)\(err.isEmpty ? "" : ": \(err)")")
        }
    }
}
