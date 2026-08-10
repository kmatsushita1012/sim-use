// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ObjectiveC
import SimUseCore

/// Produces unified `Device` rows from CoreSimulator's device set.
///
/// Why a separate utility from `DeviceResolver`: the resolver only ever
/// cares about *booted* sims (its job is "find the one I should talk
/// to"), so its parser drops state and runtime. The device-listing
/// verb needs both — picking a sim to interact with is a different
/// question from picking which one to boot.
public enum SimctlDeviceLister {
    public enum ListerError: Error, LocalizedError {
        case simctlFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .simctlFailed(let m): return "CoreSimulator bridge failed: \(m)"
            }
        }
    }

    public static func listDevices(bootedOnly: Bool) throws -> [Device] {
        loadCoreSimulator()
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
            throw ListerError.simctlFailed(message: "CoreSimulator.framework is unavailable")
        }
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = contextClass.perform(
            contextSelector,
            with: developerDirectory,
            with: nil
        )?.takeUnretainedValue() as? NSObject else {
            throw ListerError.simctlFailed(message: "CoreSimulator service context is unavailable")
        }
        let deviceSetSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = context.perform(deviceSetSelector, with: nil)?
            .takeUnretainedValue() as? NSObject,
              let rawDevices = deviceSet.value(forKey: "devices") as? [NSObject]
        else {
            throw ListerError.simctlFailed(message: "CoreSimulator device set is unavailable")
        }

        let devices = rawDevices.compactMap { device -> Device? in
            guard let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString,
                  let name = device.value(forKey: "name") as? String,
                  let state = device.value(forKey: "stateString") as? String
            else {
                return nil
            }
            guard !bootedOnly || state == Device.State.iosBooted else { return nil }
            let runtimeObject = device.value(forKey: "runtime") as? NSObject
            let runtimeName = runtimeObject?.value(forKey: "name") as? String
            let runtimeIdentifier = runtimeObject?.value(forKey: "identifier") as? String
                ?? device.value(forKey: "runtimeIdentifier") as? String
            return Device(
                udid: udid,
                name: name,
                platform: .ios,
                state: state,
                runtime: runtimeName ?? runtimeIdentifier.map(friendlyRuntime)
            )
        }
        return devices.sorted { lhs, rhs in
            if lhs.runtime != rhs.runtime { return (lhs.runtime ?? "") < (rhs.runtime ?? "") }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.udid < rhs.udid
        }
    }

    private static var developerDirectory: String {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["DEVELOPER_DIR"], !value.isEmpty { return value }
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

    /// Parses the legacy device-list JSON shape:
    ///   { "devices": { "<runtimeId>": [ { "udid", "name", "state", ... }, ... ], ... } }
    ///
    /// Runtime IDs look like `com.apple.CoreSimulator.SimRuntime.iOS-18-6`.
    /// We convert them to the user-facing form `iOS 18.6` so the rendered
    /// list matches the historical CLI rendering.
    public static func parse(_ data: Data) throws -> [Device] {
        struct RawDevice: Decodable {
            public let udid: String
            public let name: String
            public let state: String
        }
        struct Envelope: Decodable {
            public let devices: [String: [RawDevice]]
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ListerError.simctlFailed(message: "could not parse simctl JSON: \(error.localizedDescription)")
        }

        var devices: [Device] = []
        for (runtimeId, raws) in envelope.devices {
            let runtime = friendlyRuntime(runtimeId)
            for raw in raws {
                devices.append(Device(
                    udid: raw.udid,
                    name: raw.name,
                    platform: .ios,
                    state: raw.state,
                    runtime: runtime
                ))
            }
        }
        // Stable order: by platform/runtime/name/udid so two runs against
        // the same set of sims produce identical output. `Device` doesn't
        // implement `Comparable` so build the key inline.
        devices.sort { a, b in
            if a.runtime != b.runtime { return (a.runtime ?? "") < (b.runtime ?? "") }
            if a.name != b.name       { return a.name < b.name }
            return a.udid < b.udid
        }
        return devices
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-6` → `iOS 18.6`.
    /// Unknown shapes fall back to the original identifier so we never
    /// silently lose information.
    public static func friendlyRuntime(_ identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return identifier }
        let tail = String(identifier.dropFirst(prefix.count))
        // Tail is e.g. `iOS-18-6` or `watchOS-26-1` or
        // `tvOS-26-2`. First `-` separates family from version; the
        // remaining `-`s are version separators that should become `.`.
        guard let firstDash = tail.firstIndex(of: "-") else { return tail }
        let family = String(tail[..<firstDash])
        let version = tail[tail.index(after: firstDash)...].replacingOccurrences(of: "-", with: ".")
        return "\(family) \(version)"
    }
}
