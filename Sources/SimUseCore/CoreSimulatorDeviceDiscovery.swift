// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ObjectiveC

/// Reads the host Simulator device set through CoreSimulator's Swift/ObjC
/// runtime surface. This is the device-resolution infrastructure used by the
/// iOS command path; it deliberately does not invoke `xcrun` or parse a CLI
/// JSON response.
enum CoreSimulatorDeviceDiscovery {
    struct BootedDevice: Equatable {
        let udid: String
        let name: String
    }

    enum DiscoveryError: Error, LocalizedError {
        case frameworkUnavailable
        case serviceUnavailable(String)
        case deviceSetUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable:
                return "CoreSimulator.framework is unavailable."
            case .serviceUnavailable(let message):
                return "CoreSimulator service context could not be opened: \(message)"
            case .deviceSetUnavailable(let message):
                return "CoreSimulator device set could not be opened: \(message)"
            }
        }
    }

    static func bootedDevices() throws -> [BootedDevice] {
        loadCoreSimulator()

        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
            throw DiscoveryError.frameworkUnavailable
        }
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let contextMethod = class_getClassMethod(contextClass, contextSelector) else {
            throw DiscoveryError.serviceUnavailable("the service-context entry point is missing")
        }
        typealias ContextFactory = @convention(c) (
            AnyObject,
            Selector,
            AnyObject?,
            UnsafeMutablePointer<NSError?>?
        ) -> AnyObject?
        let makeContext = unsafeBitCast(method_getImplementation(contextMethod), to: ContextFactory.self)
        var contextError: NSError?
        var context = makeContext(
            contextClass,
            contextSelector,
            developerDirectory as NSString,
            &contextError
        ) as? NSObject
        if context == nil {
            contextError = nil
            context = makeContext(contextClass, contextSelector, nil, &contextError) as? NSObject
        }
        guard let context else {
            throw DiscoveryError.serviceUnavailable(
                contextError?.localizedDescription ?? "the service context returned nil"
            )
        }

        let deviceSetSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSetMethod = class_getInstanceMethod(type(of: context), deviceSetSelector) else {
            throw DiscoveryError.deviceSetUnavailable("the device-set entry point is missing")
        }
        typealias DeviceSetFactory = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutablePointer<NSError?>?
        ) -> AnyObject?
        let makeDeviceSet = unsafeBitCast(method_getImplementation(deviceSetMethod), to: DeviceSetFactory.self)
        var deviceSetError: NSError?
        guard let deviceSet = makeDeviceSet(context, deviceSetSelector, &deviceSetError) as? NSObject,
              let devices = deviceSet.value(forKey: "devices") as? [NSObject]
        else {
            throw DiscoveryError.deviceSetUnavailable(
                deviceSetError?.localizedDescription ?? "the device set returned no devices"
            )
        }

        return devices.compactMap { device in
            guard let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString,
                  device.value(forKey: "stateString") as? String == "Booted",
                  let name = device.value(forKey: "name") as? String
            else {
                return nil
            }
            return BootedDevice(udid: udid, name: name)
        }
        .sorted { $0.udid < $1.udid }
    }

    private static var developerDirectory: String {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["DEVELOPER_DIR"], !value.isEmpty {
            return value
        }
        let selectedPath = "/var/db/xcode_select_link"
        if let value = try? FileManager.default.destinationOfSymbolicLink(atPath: selectedPath),
           !value.isEmpty
        {
            return value
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    private static func loadCoreSimulator() {
        let candidates = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator",
            "\(developerDirectory)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        for path in candidates {
            _ = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        }
    }
}
