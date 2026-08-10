// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import Foundation
import ObjectiveC
import FBSimulatorControl

/// Direct host-to-Simulator pasteboard bridge.
///
/// The legacy simulator paste command is a convenience wrapper around the
/// same private CoreSimulator services. Keeping the bridge here means callers
/// never need to fork a host process or know about an stdin protocol. Xcode 26.2 and older
/// expose `SimDevicePasteboard`; newer Xcode releases use the weak-linked
/// `SimPasteboardPlus` interface. Both implementations are resolved at
/// runtime so one binary can run against either Xcode generation.
public enum IOSSimulatorPasteboard {
    public enum BridgeError: Error, LocalizedError, Sendable {
        case simulatorPasteboardUnavailable
        case pasteboardWriteFailed(String)
        case simulatorNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .simulatorPasteboardUnavailable:
                return "The selected Xcode does not expose a usable Simulator pasteboard bridge."
            case .pasteboardWriteFailed(let message):
                return "Could not write the Simulator pasteboard: \(message)"
            case .simulatorNotFound(let udid):
                return "Simulator \(udid) was not found."
            }
        }
    }

    /// Writes text to an already-connected FBSimulator without spawning a
    /// process or touching the shell.
    public static func write(text: String, to simulator: FBSimulator) throws {
        loadPasteboardFrameworks()

        if try writeUsingModernPasteboard(text: text, simulator: simulator) {
            return
        }
        if try writeUsingLegacyPasteboard(text: text, simulator: simulator) {
            return
        }
        throw BridgeError.simulatorPasteboardUnavailable
    }

    /// Resolves a Simulator through FBSimulatorControl and writes its
    /// pasteboard. This is the application-facing convenience entry point.
    public static func write(text: String, udid: String) async throws {
        let logger = SimUseLogger(silent: true)
        try await performGlobalSetup(logger: logger)
        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )
        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == udid }) else {
            throw BridgeError.simulatorNotFound(udid)
        }
        guard simulator.state == .booted else {
            throw BridgeError.pasteboardWriteFailed("Simulator \(udid) is not booted.")
        }
        try write(text: text, to: simulator)
    }

    // MARK: - Runtime bridge

    private static func loadPasteboardFrameworks() {
        let paths = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator",
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Frameworks/SimPasteboardPlus.framework/Versions/A/SimPasteboardPlus",
        ]
        for path in paths {
            _ = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        }
    }

    private static func writeUsingModernPasteboard(text: String, simulator: FBSimulator) throws -> Bool {
        let listenerName = "_TtC17SimPasteboardPlus30SimPasteboardInterfaceListener"
        let interfaceName = "_TtC17SimPasteboardPlus22SimPasteboardInterface"
        guard let listenerClass = NSClassFromString(listenerName),
              let interfaceClass = NSClassFromString(interfaceName),
              let machServiceName = classPropertyString(
                  listenerClass,
                  selector: NSSelectorFromString("machServiceName")
              )
        else {
            return false
        }

        guard let device = (simulator as NSObject).value(forKey: "device") as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("FBSimulator did not expose its CoreSimulator device.")
        }
        let port = try lookup(
            serviceName: machServiceName,
            on: device
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.simuse.pasteboard.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw BridgeError.pasteboardWriteFailed("NSPasteboard rejected the text payload.")
        }

        let selector = NSSelectorFromString(
            "initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:"
        )
        guard let method = class_getInstanceMethod(interfaceClass, selector) else {
            return false
        }
        guard let allocated = class_createInstance(interfaceClass, 0) as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus could not allocate its interface.")
        }
        typealias Initializer = @convention(c) (
            AnyObject,
            Selector,
            UInt32,
            AnyObject,
            AnyObject?,
            AnyObject?
        ) -> AnyObject?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        guard let interface = initialize(
            allocated,
            selector,
            port,
            pasteboard,
            nil,
            DispatchQueue.global(qos: .utility)
        ) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus could not connect to the device.")
        }

        guard interface.responds(to: NSSelectorFromString("push")) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus does not support push.")
        }
        _ = interface.perform(NSSelectorFromString("push"))
        return true
    }

    private static func writeUsingLegacyPasteboard(text: String, simulator: FBSimulator) throws -> Bool {
        guard let itemClass = NSClassFromString("SimPasteboardItem") else {
            return false
        }
        guard let device = (simulator as NSObject).value(forKey: "device") as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("FBSimulator did not expose its CoreSimulator device.")
        }
        guard let pasteboard = device.value(forKey: "pasteboard") as? NSObject else {
            return false
        }

        let item = try makeLegacyItem(
            itemClass: itemClass,
            text: text,
            type: "public.utf8-plain-text"
        )
        let selector = NSSelectorFromString("setPasteboardWithItems:error:")
        guard let method = class_getInstanceMethod(type(of: pasteboard), selector) else {
            return false
        }
        typealias Setter = @convention(c) (
            AnyObject,
            Selector,
            NSArray,
            UnsafeMutablePointer<NSError?>?
        ) -> UInt64
        let setItems = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        var error: NSError?
        _ = setItems(pasteboard, selector, [item], &error)
        if let error {
            throw BridgeError.pasteboardWriteFailed(error.localizedDescription)
        }
        return true
    }

    private static func makeLegacyItem(
        itemClass: AnyClass,
        text: String,
        type: String
    ) throws -> NSObject {
        guard let item = class_createInstance(itemClass, 0) as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem could not be allocated.")
        }
        let initSelector = NSSelectorFromString("init")
        guard let initMethod = class_getInstanceMethod(itemClass, initSelector) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem could not be initialized.")
        }
        typealias Initializer = @convention(c) (AnyObject, Selector) -> AnyObject?
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initializer.self)
        guard let initialized = initialize(item, initSelector) as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem initialization failed.")
        }

        let setSelector = NSSelectorFromString("setValue:forType:")
        guard let setMethod = class_getInstanceMethod(itemClass, setSelector) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem does not support text values.")
        }
        typealias ValueSetter = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
        let setValue = unsafeBitCast(method_getImplementation(setMethod), to: ValueSetter.self)
        guard setValue(initialized, setSelector, text as NSString, type as NSString) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem rejected the text payload.")
        }
        return initialized
    }

    private static func classPropertyString(_ type: AnyClass, selector propertySelector: Selector) -> String? {
        guard let method = class_getClassMethod(type, propertySelector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let getValue = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getValue(type, propertySelector) as? String
    }

    private static func lookup(serviceName: String, on device: NSObject) throws -> UInt32 {
        let selector = NSSelectorFromString("lookup:error:")
        guard let method = class_getInstanceMethod(type(of: device), selector) else {
            throw BridgeError.pasteboardWriteFailed("CoreSimulator does not expose device service lookup.")
        }
        typealias Lookup = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            UnsafeMutablePointer<NSError?>?
        ) -> UInt32
        let findPort = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        var error: NSError?
        let port = findPort(device, selector, serviceName as NSString, &error)
        if let error {
            throw BridgeError.pasteboardWriteFailed(error.localizedDescription)
        }
        guard port != 0 else {
            throw BridgeError.pasteboardWriteFailed("The Simulator pasteboard service is unavailable.")
        }
        return port
    }
}
