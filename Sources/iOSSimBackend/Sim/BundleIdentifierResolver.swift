// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ObjectiveC
import SimUseCore

/// Resolves the `CFBundleIdentifier` of a simulator's frontmost app.
///
/// Strategy: read the AX-root element's `pid` (every AX node carries
/// `pid` per the FBSimulatorControl serializer), then look the pid up
/// against the Simulator's CoreSimulator `SimDevice.spawn` API. Each row is
/// `<pid> <status> UIKitApplication:<bundleId>[xxxx][xxxx]` for hosted
/// apps; we extract the bundle id from the label.
///
/// Returns empty string when the AX root has no pid, when the Simulator is
/// unreachable, or when the pid isn't a UIKitApplication. `describe-ui`
/// treats appPackage as hint-grade, not authoritative — failing to
/// resolve is non-fatal.
public enum BundleIdentifierResolver {

    /// Production resolver. Pulls pid from the root element and asks the
    /// target SimDevice's private process-inspection service.
    public static func resolve(udid: String, rootElement: AccessibilityElement?) -> String {
        guard let pid = rootElement?.pid, pid > 0 else { return "" }
        guard let output = try? runLaunchctlList(udid: udid) else { return "" }
        return parseForeground(launchctlOutput: output, pid: pid) ?? ""
    }

    /// Foreground resolver that reuses a liveness snapshot when it already
    /// carries the root pid, saving a redundant `launchctl` spawn on the
    /// describe-ui hot path (the daemon probes liveness right before the
    /// command runs — issue #81 perf follow-up). A miss (no root pid, or a
    /// pid the liveness probe excludes — SpringBoard's daemon label) falls
    /// back to a fresh `resolve`, so the crashed-to-home header stays
    /// correct. `cachedSnapshot == nil` (standalone, probe failed, or
    /// detection disabled) is always a fresh resolve — no behavioural
    /// change from the un-cached path.
    public static func resolve(
        udid: String,
        rootElement: AccessibilityElement?,
        cachedSnapshot: AppSnapshot?
    ) -> String {
        if let pid = rootElement?.pid, pid > 0,
           let bundleId = cachedSnapshot?.appsByPid[pid] {
            return bundleId
        }
        return resolve(udid: udid, rootElement: rootElement)
    }

    /// Parser exposed for tests. Returns the bundle id when the input
    /// contains a `UIKitApplication:<bundleId>[…]` row for `pid`.
    ///
    /// The `label` column is conventionally a single whitespace-free
    /// token (launchctl labels never contain spaces — the system
    /// uses dots / hyphens / colons). The `count >= 3` guard
    /// already ensures `columns.last` is non-nil, but `if let`
    /// keeps the destructure honest without the force-unwrap.
    public static func parse(launchctlOutput: String, pid: Int) -> String? {
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3 else { continue }
            guard let rowPid = Int(columns[0]), rowPid == pid else { continue }
            guard let last = columns.last else { continue }
            return bundleId(fromLabel: String(last))
        }
        return nil
    }

    /// Parses every *running* `UIKitApplication:` row into a
    /// `[pid: bundleId]` map for liveness tracking. Rows without a
    /// numeric pid (`-`, i.e. installed-but-not-running) and
    /// non-`UIKitApplication` labels (system daemons, including
    /// SpringBoard's daemon label) are excluded, so the map contains
    /// only live hosted apps. Pure; exposed for tests and for building
    /// an `AppSnapshot`.
    public static func appsByPid(launchctlOutput: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3,
                  let pid = Int(columns[0]),
                  let last = columns.last,
                  let bundleId = bundleId(fromLabel: String(last))
            else { continue }
            map[pid] = bundleId
        }
        return map
    }

    /// Build an `AppSnapshot` of the simulator's live hosted apps.
    /// Returns `nil` when the private process inspection fails or times out — a
    /// probe failure is "unknown", distinct from a genuinely empty device.
    /// The liveness tracker treats `nil` as "skip this command" rather
    /// than "everything died", so a transient Simulator bridge hiccup can't fake a
    /// mass disappearance (issue #81).
    public static func appSnapshot(udid: String) -> AppSnapshot? {
        guard let output = try? runLaunchctlList(udid: udid) else {
            return nil
        }
        return AppSnapshot(appsByPid: appsByPid(launchctlOutput: output))
    }

    /// SpringBoard runs under the plain daemon label `com.apple.SpringBoard`
    /// (not `UIKitApplication:`), yet it IS the foreground after a
    /// foreground app crashes to the home screen. Map it to its canonical
    /// lowercase bundle id so `ForegroundLabel` can render "SpringBoard"
    /// instead of an empty header (issue #81).
    static let springBoardDaemonLabel = "com.apple.SpringBoard"
    static let springBoardBundleId = "com.apple.springboard"

    /// Foreground-resolution variant of `bundleId(fromLabel:)`: also
    /// recognises SpringBoard's daemon label. Used by `resolve` (header
    /// reconciliation) but NOT by `appsByPid` (liveness), so SpringBoard
    /// is never tracked as an "app under test".
    public static func foregroundBundleId(fromLabel label: String) -> String? {
        if let app = bundleId(fromLabel: label) { return app }
        if label == springBoardDaemonLabel { return springBoardBundleId }
        return nil
    }

    /// Like `parse`, but resolves SpringBoard too (see `foregroundBundleId`).
    public static func parseForeground(launchctlOutput: String, pid: Int) -> String? {
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3, let rowPid = Int(columns[0]), rowPid == pid else { continue }
            guard let last = columns.last else { continue }
            return foregroundBundleId(fromLabel: String(last))
        }
        return nil
    }

    /// Pulls `com.example.app` out of `UIKitApplication:com.example.app[1234][...]`.
    /// Returns nil for non-UIKitApplication labels (e.g. system daemons).
    public static func bundleId(fromLabel label: String) -> String? {
        let prefix = "UIKitApplication:"
        guard label.hasPrefix(prefix) else { return nil }
        let trimmed = label.dropFirst(prefix.count)
        if let bracket = trimmed.firstIndex(of: "[") {
            return String(trimmed[..<bracket])
        }
        return String(trimmed)
    }

    // MARK: - CoreSimulator bridge

    /// A device spawn can wedge if the target simulator is
    /// mid-boot / mid-shutdown — `waitUntilExit()` then blocks the
    /// describe-ui path indefinitely. The pid-resolution itself is
    /// strictly best-effort (`describe-ui` treats appPackage as a
    /// hint), so cap the spawn at 5 s and treat a timeout as
    /// "couldn't resolve" rather than letting it hang the whole
    /// command.
    private static let launchctlTimeout: TimeInterval = 5

    private static func runLaunchctlList(udid: String) throws -> String {
        guard let device = findSimulator(udid: udid) else {
            throw NSError(
                domain: "BundleIdentifierResolver",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Simulator \(udid) was not found."]
            )
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let options = NSMutableDictionary()
        options.setObject(
            NSArray(array: ["launchctl", "list"]),
            forKey: "arguments" as NSString
        )
        options.setObject(
            NSNumber(value: stdoutPipe.fileHandleForWriting.fileDescriptor),
            forKey: "stdout" as NSString
        )
        options.setObject(
            NSNumber(value: stderrPipe.fileHandleForWriting.fileDescriptor),
            forKey: "stderr" as NSString
        )
        options.setObject(NSNumber(value: true), forKey: "standalone" as NSString)

        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            stdoutData.append(chunk)
            outputLock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            stderrData.append(chunk)
            outputLock.unlock()
        }

        let finished = DispatchSemaphore(value: 0)
        let statusLock = NSLock()
        var status: Int32 = -1
        let terminationHandler: @convention(block) (Int32) -> Void = { value in
            statusLock.lock()
            status = value
            statusLock.unlock()
            finished.signal()
        }

        let selector = NSSelectorFromString(
            "spawnWithPath:options:terminationQueue:terminationHandler:pid:error:"
        )
        guard class_getInstanceMethod(type(of: device), selector) != nil else {
            throw NSError(
                domain: "BundleIdentifierResolver",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "CoreSimulator does not expose SimDevice.spawn."]
            )
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            throw NSError(
                domain: "BundleIdentifierResolver",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Objective-C messaging is unavailable."]
            )
        }
        typealias Spawn = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            NSDictionary?,
            AnyObject?,
            AnyObject?,
            UnsafeMutablePointer<Int32>?,
            UnsafeMutablePointer<NSError?>?
        ) -> Bool
        let spawn = unsafeBitCast(message, to: Spawn.self)
        var pid: Int32 = 0
        var spawnError: NSError?
        let terminationHandlerObject = unsafeBitCast(terminationHandler, to: AnyObject.self)
        let succeeded = spawn(
            device,
            selector,
            "/bin/launchctl",
            options,
            nil,
            terminationHandlerObject,
            &pid,
            &spawnError
        )
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        guard succeeded else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw spawnError ?? NSError(
                domain: "BundleIdentifierResolver",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "CoreSimulator failed to run launchctl."]
            )
        }
        guard finished.wait(timeout: .now() + launchctlTimeout) == .success else {
            let signalSent = terminateSpawnedProcess(device: device, pid: pid)
            let reaped = finished.wait(timeout: .now() + 0.5) == .success
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if reaped {
                _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            } else {
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
            }
            let terminationMessage = (signalSent || reaped)
                ? ""
                : " CoreSimulator could not terminate the spawned process."
            throw NSError(
                domain: "BundleIdentifierResolver",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Simulator launchctl timed out after \(launchctlTimeout)s.\(terminationMessage)"]
            )
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        outputLock.lock()
        stdoutData.append(stdoutRemainder)
        stderrData.append(stderrRemainder)
        let output = stdoutData
        let errorOutput = stderrData
        outputLock.unlock()

        statusLock.lock()
        let exitStatus = status
        statusLock.unlock()
        guard exitStatus == 0 else {
            throw NSError(
                domain: "BundleIdentifierResolver",
                code: Int(exitStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: errorOutput, encoding: .utf8) ?? ""]
            )
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    private static func terminateSpawnedProcess(device: NSObject, pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let selector = NSSelectorFromString("sendSignalToProcess:signal:error:")
        guard class_getInstanceMethod(type(of: device), selector) != nil,
              let message = dynamicSymbol(named: "objc_msgSend")
        else {
            return false
        }
        typealias Signal = @convention(c) (
            AnyObject,
            Selector,
            Int32,
            Int32,
            UnsafeMutablePointer<NSError?>?
        ) -> Bool
        let sendSignal = unsafeBitCast(message, to: Signal.self)
        var error: NSError?
        return sendSignal(device, selector, pid, Int32(SIGKILL), &error)
    }

    private static func dynamicSymbol(named name: String) -> UnsafeMutableRawPointer? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: UInt.max - 1)
        return dlsym(defaultHandle, name)
    }

    private static func findSimulator(udid: String) -> NSObject? {
        loadCoreSimulator()
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
            return nil
        }
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = contextClass.perform(
            contextSelector,
            with: developerDirectory,
            with: nil
        )?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let deviceSetSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = context.perform(deviceSetSelector, with: nil)?
            .takeUnretainedValue() as? NSObject,
              let devices = deviceSet.value(forKey: "devices") as? [NSObject]
        else {
            return nil
        }
        return devices.first {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid
        }
    }

    private static var developerDirectory: String {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["DEVELOPER_DIR"], !value.isEmpty {
            return value
        }
        if let selected = try? FileManager.default
            .destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
           !selected.isEmpty
        {
            return selected
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    private static func loadCoreSimulator() {
        let paths = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator",
            "\(developerDirectory)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        ]
        for path in paths {
            _ = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        }
    }
}
