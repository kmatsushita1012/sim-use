// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import Foundation
import SimUseKit
import Testing

/// The Viewer API is backed by injected typed Swift closures. These tests
/// cover the HTTP mapping without starting a CLI process or decoding a CLI
/// envelope.
@Suite("ViewerAPIHandlers direct Swift bridge")
struct ViewerAPIHandlersTests {
    private enum TestError: Error, LocalizedError {
        case failed

        var errorDescription: String? { "fixture failed" }
    }

    private let device = Device(
        udid: "TEST-UDID",
        name: "iPhone Fixture",
        platform: .ios,
        kind: .simulator,
        state: Device.State.iosBooted,
        runtime: "iOS 18.6"
    )

    private var uiResult: UIResult {
        UIResult(
            platform: "ios",
            raw: nil,
            outline: "App: Fixture 100x200",
            entries: [],
            lists: [],
            screen: Outline.Frame(x: 0, y: 0, width: 100, height: 200),
            appLabel: "Fixture",
            appPackage: "com.example.fixture",
            orientation: "landscape-right"
        )
    }

    private func makeHandlers(
        list: @escaping @Sendable () async throws -> [Device] = { [] },
        describe: @escaping @Sendable (SimulatorID) async throws -> UIResult = { _ in
            throw TestError.failed
        },
        tap: @escaping @Sendable (SimulatorID, Int) async throws -> TapResult = { _, _ in
            throw TestError.failed
        }
    ) -> ViewerAPIHandlers {
        ViewerAPIHandlers(
            listDevices: list,
            describeUI: describe,
            tap: tap
        )
    }

    private func request(
        method: String = "GET",
        path: String = "/api",
        query: [String: String] = [:],
        body: Data = Data()
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: query, headers: [:], body: body)
    }

    private func tapRequest(deviceId: String = "TEST-UDID", at: Int = 1) throws -> HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "at": at])
        return request(method: "POST", path: "/api/tap", body: body)
    }

    private func jsonBody(_ response: HTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test("devices maps typed Device values directly")
    func devicesSuccess() async throws {
        let handlers = makeHandlers(list: { [device] })
        let response = await handlers.devices(request())

        #expect(response.status == 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == true)
        let devices = try #require(body["devices"] as? [[String: Any]])
        #expect(devices.first?["deviceId"] as? String == "TEST-UDID")
        #expect(devices.first?["platform"] as? String == "ios")
        #expect(devices.first?["kind"] as? String == "simulator")
    }

    @Test("Viewer excludes physical iOS devices")
    func devicesExcludePhysicalIOS() async throws {
        let physical = Device(
            udid: "PHYSICAL-UDID",
            name: "Physical iPhone",
            platform: .ios,
            kind: .physical,
            state: Device.State.iosBooted,
            runtime: "iOS 27"
        )
        let handlers = makeHandlers(list: { [device, physical] })
        let response = await handlers.devices(request())
        let body = try jsonBody(response)
        let devices = try #require(body["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        #expect(devices.first?["deviceId"] as? String == "TEST-UDID")
    }

    @Test("snapshot maps UIResult without a CLI envelope")
    func snapshotSuccess() async throws {
        let handlers = makeHandlers(describe: { [uiResult] _ in uiResult })
        let response = await handlers.snapshot(request(query: ["deviceId": "TEST-UDID"]))

        #expect(response.status == 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == true)
        #expect(body["outline"] as? String == "App: Fixture 100x200")
        let screen = try #require(body["screen"] as? [String: Any])
        #expect(screen["orientation"] as? String == "landscape-right")
    }

    @Test("tap maps typed TapResult directly")
    func tapSuccess() async throws {
        let handlers = makeHandlers(tap: { _, at in
            TapResult(x: Double(at), y: 2)
        })
        let response = await handlers.tap(try tapRequest(at: 7))

        #expect(response.status == 200)
        let body = try jsonBody(response)
        #expect(body["ok"] as? Bool == true)
        #expect(body["at"] as? Int == 7)
    }

    @Test("validation happens before a direct operation")
    func validation() async throws {
        let handlers = makeHandlers()
        let response = await handlers.snapshot(request())
        #expect(response.status == 400)

        let invalidBody = try JSONSerialization.data(withJSONObject: ["deviceId": "TEST-UDID", "at": 0])
        let invalidTap = await handlers.tap(request(method: "POST", path: "/api/tap", body: invalidBody))
        #expect(invalidTap.status == 400)
    }

    @Test("typed operation failures are surfaced as HTTP errors")
    func directFailure() async throws {
        let handlers = makeHandlers(list: { throw TestError.failed })
        let response = await handlers.devices(request())
        #expect(response.status == 502)
        let body = try jsonBody(response)
        #expect((body["error"] as? String) == "fixture failed")
    }
}
