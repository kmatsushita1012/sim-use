// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import Foundation
import ObjectiveC
import FBSimulatorControl
import FBControlCore

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
        let logger = SimUseLogger()
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
        guard class_getInstanceMethod(interfaceClass, selector) != nil else {
            return false
        }
        guard let allocated = allocateObject(interfaceClass) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus could not allocate its interface.")
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            throw BridgeError.pasteboardWriteFailed("Objective-C messaging is unavailable.")
        }
        typealias Initializer = @convention(c) (
            AnyObject,
            Selector,
            UInt32,
            AnyObject,
            AnyObject?,
            AnyObject?
        ) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(message, to: Initializer.self)
        guard let initialized = initialize(
            allocated.takeUnretainedValue(),
            selector,
            port,
            pasteboard,
            nil,
            DispatchQueue.global(qos: .utility)
        ), let interface = initialized.takeRetainedValue() as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus could not connect to the device.")
        }

        let pushSelector = NSSelectorFromString("push")
        guard let pushMethod = class_getInstanceMethod(interfaceClass, pushSelector) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus does not support push.")
        }
        guard let pushEncoding = method_getTypeEncoding(pushMethod),
              String(cString: pushEncoding) == "v16@0:8" else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardPlus exposes an unsupported push signature.")
        }
        guard sendVoidMessage(to: interface, selector: pushSelector) else {
            throw BridgeError.pasteboardWriteFailed("Objective-C messaging is unavailable.")
        }
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
        guard class_getInstanceMethod(type(of: pasteboard), selector) != nil else {
            return false
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            throw BridgeError.pasteboardWriteFailed("Objective-C messaging is unavailable.")
        }
        typealias Setter = @convention(c) (
            AnyObject,
            Selector,
            NSArray,
            UnsafeMutablePointer<NSError?>?
        ) -> UInt64
        let setItems = unsafeBitCast(message, to: Setter.self)
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
        guard let item = allocateObject(itemClass) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem could not be allocated.")
        }
        let initSelector = NSSelectorFromString("init")
        guard class_getInstanceMethod(itemClass, initSelector) != nil else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem could not be initialized.")
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            throw BridgeError.pasteboardWriteFailed("Objective-C messaging is unavailable.")
        }
        typealias Initializer = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(message, to: Initializer.self)
        guard let initialized = initialize(item.takeUnretainedValue(), initSelector),
              let initialized = initialized.takeRetainedValue() as? NSObject else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem initialization failed.")
        }

        let setSelector = NSSelectorFromString("setValue:forType:")
        guard class_getInstanceMethod(itemClass, setSelector) != nil else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem does not support text values.")
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            throw BridgeError.pasteboardWriteFailed("Objective-C messaging is unavailable.")
        }
        typealias ValueSetter = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
        let setValue = unsafeBitCast(message, to: ValueSetter.self)
        guard setValue(initialized, setSelector, text as NSString, type as NSString) else {
            throw BridgeError.pasteboardWriteFailed("SimPasteboardItem rejected the text payload.")
        }
        return initialized
    }

    private static func classPropertyString(_ type: AnyClass, selector propertySelector: Selector) -> String? {
        guard class_getClassMethod(type, propertySelector) != nil else {
            return nil
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getValue = unsafeBitCast(message, to: Getter.self)
        return getValue(type, propertySelector)?.takeUnretainedValue() as? String
    }

    private static func allocateObject(_ type: AnyClass) -> Unmanaged<AnyObject>? {
        guard let symbol = dynamicSymbol(named: "class_createInstance") else {
            return nil
        }
        typealias Allocate = @convention(c) (AnyClass, Int) -> Unmanaged<AnyObject>?
        let allocate = unsafeBitCast(symbol, to: Allocate.self)
        return allocate(type, 0)
    }

    private static func dynamicSymbol(named name: String) -> UnsafeMutableRawPointer? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: UInt.max - 1)
        return dlsym(defaultHandle, name)
    }

    private static func sendVoidMessage(to receiver: AnyObject, selector: Selector) -> Bool {
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            return false
        }
        typealias Message = @convention(c) (AnyObject, Selector) -> Void
        let send = unsafeBitCast(message, to: Message.self)
        send(receiver, selector)
        return true
    }

    private static func lookup(serviceName: String, on device: NSObject) throws -> UInt32 {
        let selector = NSSelectorFromString("lookup:error:")
        guard class_getInstanceMethod(type(of: device), selector) != nil else {
            throw BridgeError.pasteboardWriteFailed("CoreSimulator does not expose device service lookup.")
        }
        guard let message = dynamicSymbol(named: "objc_msgSend") else {
            throw BridgeError.pasteboardWriteFailed("Objective-C messaging is unavailable.")
        }
        typealias Lookup = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            UnsafeMutablePointer<NSError?>?
        ) -> UInt32
        let findPort = unsafeBitCast(message, to: Lookup.self)
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
