import Testing
import SimUseKit

@Suite("SimUseKit public API visibility")
struct PublicAPIVisibilityTests {
    @Test("HIDEvent exposes native shake")
    func hidEventShakeIsPublic() {
        let event: HIDEvent = .shake
        _ = event
    }

    @Test("HIDEvent exposes named iOS hardware buttons")
    func namedHardwareButtonsArePublic() {
        let events: [HIDEvent] = [.applePay, .sideButton, .siri]
        #expect(events.count == 3)
    }
}
