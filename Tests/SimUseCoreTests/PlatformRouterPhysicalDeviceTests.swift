// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SimUseCore

@Suite("PlatformRouter — physical iOS device shape")
struct PlatformRouterPhysicalDeviceTests {
    @Test("modern 8-16-hex device UDID is recognised as physical")
    func modernShapeIsPhysical() {
        #expect(PlatformRouter.looksLikePhysicalIOSDevice("00008130-00066D2A10EB8D3A"))
        #expect(PlatformRouter.looksLikePhysicalIOSDevice("00008140-000210603a40801c"))
    }

    @Test("legacy 40-hex device UDID is recognised as physical")
    func legacyShapeIsPhysical() {
        #expect(PlatformRouter.looksLikePhysicalIOSDevice("a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0"))
    }

    @Test("simulator UDID and Android serials are not physical")
    func otherShapesAreNotPhysical() {
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("12345678-1234-1234-1234-123456789ABC"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("emulator-5554"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("R5CT1ABCD12"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("0123456789ABCDEF"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("192.168.1.5:5555"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice(""))
    }

    @Test("near-misses of the modern shape stay out of the physical class")
    func nearMissesAreNotPhysical() {
        // 15-hex tail, non-hex character, missing dash.
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("00008130-00066D2A10EB8D3"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("00008130-00066D2A10EB8DZZ"))
        #expect(!PlatformRouter.looksLikePhysicalIOSDevice("0000813000066D2A10EB8D3A"))
    }

    @Test("physical device UDID is never classified as Android")
    func physicalShapeExcludedFromAndroid() {
        // Before the exclusion the modern shape cleared Android rule 3
        // (hex + dash, 25 chars, contains digits) and a plugged-in
        // iPhone was diagnosed as an unreachable adb serial.
        #expect(!PlatformRouter.looksLikeAndroid("00008130-00066D2A10EB8D3A"))
    }

    @Test("physical device shapes resolve to the iOSDevice platform")
    func physicalShapesResolveToIOSDevice() {
        #expect(PlatformRouter.resolve(udid: "00008130-00066D2A10EB8D3A") == .iOSDevice)
        #expect(PlatformRouter.resolve(udid: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0") == .iOSDevice)
        // Whitespace-tolerant like the other shapes.
        #expect(PlatformRouter.resolve(udid: " 00008130-00066D2A10EB8D3A ") == .iOSDevice)
        // ECIDs stay invisible to shape routing (documented non-goal).
        #expect(PlatformRouter.resolve(udid: "1234567890123456") == .android)
    }

    @Test("real Android serials keep matching after the exclusion")
    func androidSerialsUnaffected() {
        #expect(PlatformRouter.looksLikeAndroid("emulator-5554"))
        #expect(PlatformRouter.looksLikeAndroid("R5CT1ABCD12"))
        #expect(PlatformRouter.looksLikeAndroid("0123456789ABCDEF"))
        #expect(PlatformRouter.looksLikeAndroid("192.168.1.5:5555"))
    }
}
