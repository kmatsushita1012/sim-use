// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import SimUseKit

@Suite("SimUseKit public API")
struct SimUseKitTests {
    @Test("SimulatorID is a stable value type")
    func simulatorID() {
        let id = SimulatorID("SIM-1")
        #expect(id.rawValue == "SIM-1")
        #expect(id == "SIM-1")
    }

    @Test("typed touch sequence preserves event order")
    func touchSequenceRequest() {
        let request = TouchSequenceRequest(events: [
            .touchDown(x: 1, y: 2),
            .touchMove(x: 3, y: 4),
            .touchUp(x: 3, y: 4),
        ])
        #expect(request.events.count == 3)
    }

    @Test("request defaults do not depend on CLI parsing")
    func describeDefaults() {
        let request = DescribeUIRequest()
        #expect(request.maxProbes == 300)
        #expect(request.minCellSize == 14)
        #expect(request.seedCellWidth == 160)
        #expect(request.seedCellHeight == 80)
    }

    @Test("cross-platform requests preserve typed command intent")
    func crossPlatformRequests() {
        let request = LongPressRequest(
            target: TapRequest(accessibilityIdentifier: "moreButton"),
            duration: 0.8
        )
        #expect(request.target.accessibilityIdentifier == "moreButton")
        #expect(request.duration == 0.8)

        let state = AppStateResult(
            platform: "ios",
            apps: [AppProcess(bundleID: "com.example.app", pid: 42)],
            query: AppStateQuery(bundleID: "com.example.app", state: .running),
            didReset: false
        )
        #expect(state.query?.state == .running)

        let video = VideoStreamConfiguration()
        #expect(video.framesPerSecond == 10)
        #expect(video.quality == 80)
        #expect(video.scale == 1.0)

        let screenshot = ScreenshotResult(data: Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(screenshot.data.count == 4)
    }

    @Test("text input is represented by an application-facing request")
    func textRequest() {
        let request = TextRequest("Hello!")
        #expect(request.text == "Hello!")
    }

    @Test("GesturePreset is directly visible from SimUseKit")
    func gesturePresetIsPublic() {
        let preset: GesturePreset = .scrollUp
        #expect(preset == .scrollUp)
    }

    @Test("text request rejects unsupported characters before dispatch")
    func textRequestRejectsUnsupportedCharacters() async {
        let request = TextRequest("こんにちは")
        do {
            _ = try await request.execute(on: SimulatorID("SIM-1"), using: SimUseClient())
            Issue.record("Expected unsupported text to fail")
        } catch let error as TextRequestError {
            #expect(error == .unsupportedCharacter("こ"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("legacy gesture aliases are usable through SimUseKit alone")
    func legacyGestureAlias() {
        var command = IOSGestureCommand()
        command.preset = .scrollUp
        command.steps = 10
        #expect(command.preset == .scrollUp)

        var implementationName = IOSSimGestureCommand()
        implementationName.preset = .scrollDown
        #expect(implementationName.preset == .scrollDown)

        let result: IOSSimGestureCommand.ExecutionResult = .init()
        _ = result

        let request = GestureRequest(preset: .scrollUp)
        #expect(request.preset == .scrollUp)
    }
}
