// SPDX-License-Identifier: Apache-2.0
import SimUseKit
import Testing

@Suite("SimUseKit import-only public API")
struct PublicAPIVisibilityTests {
    @Test("all SimUseKit facade types are reachable with only import SimUseKit")
    func facadeTypesArePublic() {
        requirePublicType(SimUseClient.self)
        requirePublicType(SimulatorSession.self)
        requirePublicType(SimulatorID.self)
        requirePublicType(HIDEvent.self)
        requirePublicType(HIDEventTiming.self)
        requirePublicType(SimUseError.self)

        requirePublicType(TouchSequenceRequest.self)
        requirePublicType(EmptyCommandResult.self)
        requirePublicType(DescribeUIRequest.self)
        requirePublicType(UIResult.self)
        requirePublicType(TapRequest.self)
        requirePublicType(TapResult.self)
        requirePublicType(SwipeRequest.self)
        requirePublicType(SwipeResult.self)
        requirePublicType(GestureRequest.self)
        requirePublicType(GestureResult.self)
        requirePublicType(LongPressRequest.self)
        requirePublicType(AppStateRequest.self)
        requirePublicType(AppProcess.self)
        requirePublicType(AppStateQuery.self)
        requirePublicType(AppStateQuery.State.self)
        requirePublicType(AppStateResult.self)
        requirePublicType(TextRequest.self)
        requirePublicType(TextRequestError.self)
        requirePublicType(ScreenshotRequest.self)
        requirePublicType(ScreenshotResult.self)
        requirePublicType(VideoStreamConfiguration.self)
        requirePublicType(VideoFrame.self)
        requirePublicType(GesturePreset.self)

        requirePublicType(IOSDescribeUICommand.self)
        requirePublicType(IOSTapCommand.self)
        requirePublicType(IOSSwipeCommand.self)
        requirePublicType(IOSTouchCommand.self)
        requirePublicType(IOSTypeCommand.self)
        requirePublicType(IOSPasteCommand.self)
        requirePublicType(IOSButtonCommand.self)
        requirePublicType(IOSGestureCommand.self)
        requirePublicType(IOSMultiTouchCommand.self)
        requirePublicType(IOSKeyboardStateCommand.self)
        requirePublicType(IOSKeyCommand.self)
        requirePublicType(IOSKeyComboCommand.self)
        requirePublicType(IOSKeySequenceCommand.self)
        requirePublicType(IOSBatchCommand.self)
        requirePublicType(IOSScreenshotCommand.self)
        requirePublicType(IOSRecordVideoCommand.self)
        requirePublicType(IOSStreamVideoCommand.self)

        requirePublicType(AndroidDescribeUICommand.self)
        requirePublicType(AndroidTapCommand.self)
        requirePublicType(AndroidSwipeCommand.self)
        requirePublicType(AndroidTouchCommand.self)
        requirePublicType(AndroidTypeCommand.self)
        requirePublicType(AndroidPasteCommand.self)
        requirePublicType(AndroidButtonCommand.self)
        requirePublicType(AndroidGestureCommand.self)
        requirePublicType(AndroidMultiTouchCommand.self)
        requirePublicType(AndroidScrollCommand.self)
        requirePublicType(AndroidKeyboardStateCommand.self)
        requirePublicType(AndroidDevicesCommand.self)
        requirePublicType(AndroidInitCommand.self)
        requirePublicType(AndroidPingCommand.self)
        requirePublicType(AndroidScreenshotCommand.self)

        requiresRequest(TextRequest("text"))
        requiresRequest(ScreenshotRequest())
        requiresRequest(GestureRequest(preset: .scrollUp))
        requiresRequest(TapRequest(x: 1, y: 1))
        requiresRequest(SwipeRequest(coordinates: .init(startX: 0, startY: 0, endX: 1, endY: 1)))
        requiresRequest(DescribeUIRequest())
        requiresRequest(TouchSequenceRequest(events: [.tap(x: 1, y: 1)]))
        requiresRequest(LongPressRequest(target: TapRequest(x: 1, y: 1)))
        requiresRequest(AppStateRequest())
    }

    @Test("public validation paths work without a simulator")
    func publicValidationPaths() async {
        let client = SimUseClient()

        do {
            _ = try await client.execute(TextRequest("こんにちは"), on: "SIM-1")
            Issue.record("Expected unsupported text to fail")
        } catch let error as SimUseError {
            guard case let .invalidRequest(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "No keycode found for character: 'こ'")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await client.streamVideo(
                on: "SIM-1",
                configuration: .init(framesPerSecond: 0)
            )
            Issue.record("Expected invalid stream configuration to fail")
        } catch let error as SimUseError {
            guard case let .invalidRequest(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "FPS must be between 1 and 30")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await client.execute(
                LongPressRequest(target: TapRequest(x: 1, y: 1), duration: 11),
                on: "SIM-1"
            )
            Issue.record("Expected invalid long-press duration to fail")
        } catch let error as SimUseError {
            guard case let .invalidRequest(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Long-press duration must be greater than 0 and at most 10 seconds.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await client.send([.applePay], on: "SIM-1")
            Issue.record("Expected unavailable Apple Pay input to fail")
        } catch let error as SimUseError {
            guard case let .backend(message, hint) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Apple Pay simulator input is unavailable in this release.")
            #expect(hint == "Use a supported simulator hardware action instead.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("native shake and named hardware events are public")
    func namedHIDEventsArePublic() {
        let shake: HIDEvent = .shake
        let events: [HIDEvent] = [.applePay, .sideButton, .siri]
        _ = shake
        #expect(events.count == 3)
    }

    private func requirePublicType<T>(_ type: T.Type) {
        _ = type
    }

    private func requiresRequest<Request: SimUseRequest>(_ request: Request) {
        _ = request
    }
}
