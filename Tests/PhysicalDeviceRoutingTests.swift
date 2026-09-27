// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
@testable import iOSDeviceBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

/// Top-level routing of physical iOS devices (#115 PR C): the three
/// supported verbs route to the audit/CoreDevice backends, everything
/// else rejects per verb with a `TargetCapabilityError` naming the
/// reason and the nearest alternative — before any device I/O, so all
/// of this runs without hardware.
@Suite("Physical iOS device routing")
struct PhysicalDeviceRoutingTests {
    /// Modern-shape UDID; no device with it is attached in CI.
    static let physical = "00008130-00066D2A10EB8D3A"

    // MARK: - Rejecting verbs

    @Test(
        "every non-routed verb rejects a physical UDID with the capability boundary",
        arguments: [
            "app-state",
            "button home",
            "gesture scroll-up",
            "keyboard-state",
            "long-press -x 10 -y 10",
            "multi-touch --x1 1 --y1 1 --x2 2 --y2 2 --x1-end 3 --y1-end 3 --x2-end 4 --y2-end 4",
            "paste hello",
            "record-video",
            "stream-video",
            "swipe 1,2 3,4",
            "touch -x 1 -y 1 --down",
            "type hello",
        ]
    )
    func nonRoutedVerbsReject(invocation: String) async throws {
        let result = try await TestHelpers.runSimUseCommandAllowFailure(
            "\(invocation) --device \(Self.physical)"
        )
        #expect(result.exitCode != 0, "\(invocation) must not succeed against a physical UDID")
        #expect(result.output.contains("not supported on physical iOS devices"), "\(invocation): \(result.output)")
        // Every rejection carries a recovery pointer on the hint channel.
        #expect(result.output.contains("Hint:"), "\(invocation): \(result.output)")
    }

    @Test("a physical UDID arriving via SIM_USE_DEVICE routes identically to --device")
    func envVarRoutesLikeExplicitFlag() async throws {
        // The physical check runs on the resolved value, not the flag —
        // pin that the env-var path lands in the same per-verb
        // capability rejection.
        let result = try await TestHelpers.runSimUseCommandAllowFailure(
            "type hello",
            environment: ["SIM_USE_DEVICE": Self.physical]
        )
        #expect(result.exitCode != 0)
        #expect(result.output.contains("not supported on physical iOS devices"))
    }

    @Test("a rejecting verb honours --json with the standard error envelope")
    func rejectionSpeaksJSON() async throws {
        let result = try await TestHelpers.runSimUseCommandAllowFailure(
            "swipe 1,2 3,4 --json --device \(Self.physical)"
        )
        #expect(result.exitCode != 0)
        #expect(result.output.contains("\"ok\":false"))
        #expect(result.output.contains("not supported on physical iOS devices"))
        #expect(result.output.contains("\"hint\""))
    }

    @Test("the ios namespace stays simulator-only and points at the routed surface")
    func iosNamespaceStillRejects() async throws {
        let result = try await TestHelpers.runSimUseCommandAllowFailure(
            "ios describe-ui --device \(Self.physical)"
        )
        #expect(result.exitCode != 0)
        #expect(result.output.contains("physical iOS device"))
        // The hint now points at the top-level routed verbs, not only
        // at the ios-device namespace.
        #expect(result.output.contains("sim-use ui"))
    }

    // MARK: - Tap form decision table

    private func rejection(
        _ argv: [String]
    ) throws -> TargetCapabilityError? {
        let tap = try Tap.parse(argv + ["--device", Self.physical])
        return Tap.physicalFormRejection(
            alias: tap.alias,
            targeting: tap.targeting,
            duration: tap.duration,
            timing: tap.timing,
            multiTouch: tap.multiTouch
        )
    }

    @Test("tap rejects the forms the audit channel cannot honour")
    func tapFormsReject() throws {
        // (argv, fragment expected in the verb field)
        let rejected: [([String], String)] = [
            (["-x", "10", "-y", "10"], "-x/-y"),
            (["--point", "10,10"], "-x/-y/--point"),
            (["@3"], "@N"),
            (["#3"], "#N"),
            (["#2@2"], "#N"),
            (["--label", "Send", "--duration", "0.5"], "--duration"),
            (["--value", "on"], "--value"),
            (["--label-regex", "^Send$"], "--label-regex"),
            (["--label", "Send", "--frame", "minY=0.7r"], "--frame"),
            (["--label", "Send", "--wait-timeout", "5"], "--wait-timeout"),
            (["--label", "Send", "--fingers", "2"], "--fingers"),
        ]
        for (argv, fragment) in rejected {
            let error = try rejection(argv)
            #expect(error != nil, "\(argv) should reject on physical iOS")
            #expect(error?.verb.contains(fragment) == true, "\(argv) → \(error?.verb ?? "nil")")
            #expect(error?.hint != nil, "\(argv) rejection must carry an alternative")
        }
    }

    @Test("tap keeps the audit-channel-compatible forms")
    func tapFormsRoute() throws {
        let routed: [[String]] = [
            ["#BackButton"],
            ["--id", "BackButton"],
            ["--label", "Send"],
            ["--label-contains", "Send", "--element-type", "Button"],
            // Plain waits are honoured, not rejected.
            ["--label", "Send", "--pre-delay", "0.2", "--post-delay", "0.2"],
        ]
        for argv in routed {
            #expect(try rejection(argv) == nil, "\(argv) should route on physical iOS")
        }
    }

    @Test("a #id alias containing @ stays a literal identifier, matching the simulator grammar")
    func literalIdWithAtSignRoutes() throws {
        #expect(try rejection(["#feed@home"]) == nil)
    }

    // MARK: - Result shapes

    @Test("the physical describe-ui envelope states its restricted shape")
    func describeUIPhysicalShape() throws {
        let device = IOSDeviceCommand.UI.ExecutionResult(
            outline: "Button  \"Friends\"",
            rows: [.init(depth: 0, role: "Button", label: "Friends", identifier: nil)],
            elements: 1,
            nodes: 3,
            elapsedMs: 700
        )
        let result = DescribeUI.physicalExecutionResult(from: device)

        #expect(result.platform == "ios")
        #expect(result.kind == "physical")
        #expect(result.raw == nil)
        #expect(result.entries.isEmpty)
        #expect(result.lists.isEmpty)
        #expect(result.screen == nil)
        // Byte-identical to what `ios-device ui` prints, summary line included.
        #expect(result.outline == "Button  \"Friends\"\n\n1 elements (3 nodes) in 700 ms\n")

        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(json.contains("\"kind\":\"physical\""))
        #expect(!json.contains("\"screen\""))
    }

    @Test("simulator and Android describe-ui envelopes are unchanged: no kind, screen present")
    func describeUISimShapeUnchanged() throws {
        let result = IOSSimDescribeUICommand.ExecutionResult(
            platform: "ios",
            raw: nil,
            outline: "outline",
            entries: [],
            lists: [],
            screen: .init(x: 0, y: 0, width: 390, height: 844),
            appLabel: "App",
            appPackage: "com.example"
        )
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("\"kind\""))
        #expect(json.contains("\"screen\""))
    }

    @Test("the physical tap result carries the matched element and no coordinates")
    func tapPhysicalResultShape() throws {
        let result = IOSSimTapCommand.ExecutionResult(
            action: "Activate", role: "Button", label: "Friends", identifier: "friends"
        )
        #expect(result.kind == "physical")
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("\"x\""))
        #expect(json.contains("\"kind\":\"physical\""))
        #expect(json.contains("\"action\":\"Activate\""))

        // Coordinate results stay byte-compatible: x/y present, no new keys.
        let sim = IOSSimTapCommand.ExecutionResult(x: 10, y: 20)
        let simJSON = String(decoding: try JSONEncoder().encode(sim), as: UTF8.self)
        #expect(simJSON.contains("\"x\":10"))
        #expect(!simJSON.contains("\"kind\""))
        #expect(!simJSON.contains("\"action\""))

        // Payloads from an older daemon (x/y only) still decode.
        let decoded = try JSONDecoder().decode(
            IOSSimTapCommand.ExecutionResult.self,
            from: Data("{\"x\":1.5,\"y\":2.5}".utf8)
        )
        #expect(decoded.x == 1.5)
        #expect(decoded.kind == nil)
    }

    @Test("describe-ui payloads from an older daemon (screen present, no kind) still decode")
    func describeUIOldPayloadDecodes() throws {
        // Rolling-upgrade fixture: the pre-#115 wire shape with a
        // required `screen` and no `kind` key must keep decoding after
        // `screen` went optional and `kind` was added.
        let old = """
        {"platform":"ios","raw":null,"outline":"o","entries":[],"lists":[],
         "screen":{"x":0,"y":0,"width":390,"height":844},
         "appLabel":"App","appPackage":"com.example"}
        """
        let decoded = try JSONDecoder().decode(
            IOSSimDescribeUICommand.ExecutionResult.self,
            from: Data(old.utf8)
        )
        #expect(decoded.screen == .init(x: 0, y: 0, width: 390, height: 844))
        #expect(decoded.kind == nil)
    }

    @Test("the routed tap success line matches the ios-device namespace byte-for-byte")
    func tapSummaryLineParity() throws {
        let shared = IOSSimTapCommand.ExecutionResult(
            action: "Activate", role: "Button", label: "sim-use Playground", identifier: "BackButton"
        )
        let namespace = IOSDeviceCommand.Tap.summaryLine(.init(
            action: "Activate", role: "Button", label: "sim-use Playground", identifier: "BackButton"
        ))
        #expect(shared.summaryLine == namespace)

        // Coordinate results keep the historic line.
        #expect(IOSSimTapCommand.ExecutionResult(x: 10.0, y: 20.0).summaryLine
            == "✓ Tap at (10.0, 20.0) completed successfully")
    }

    // MARK: - Daemon exclusion (#120 not landed)

    @Test("a physical target never spawns a per-UDID daemon")
    func physicalTargetStaysOutOfDaemon() async throws {
        // The rejecting verb must run entirely in-process (#120 not
        // landed); a daemon dispatch would auto-spawn and leave
        // `<udid>.pid` under the runtime base. Guarded on prior state
        // so a stale pidfile from unrelated local work can't flake it.
        let pidFile = "/tmp/sim-use-\(getuid())/\(Self.physical).pid"
        let existedBefore = FileManager.default.fileExists(atPath: pidFile)
        _ = try await TestHelpers.runSimUseCommandAllowFailure(
            "type hi --device \(Self.physical)"
        )
        if !existedBefore {
            #expect(!FileManager.default.fileExists(atPath: pidFile))
        }
    }
}
