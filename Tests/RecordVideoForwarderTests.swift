// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import SimUseVideo
import Testing

// Pins the `--gif-markers` contract between top-level `RecordVideo`,
// `IOSSimRecordVideoCommand`, and `AndroidRecordVideoCommand`: the flag
// is opt-in on every surface, parses identically, and reaches the
// backends. The recording layers below take `gifMarkers` as a required
// parameter, so the compiler already rejects an unwired Android
// forwarder; the shape check makes that contract explicit.
@Suite("RecordVideo forwarder")
struct RecordVideoForwarderTests {
    private let iosUDID = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"

    // MARK: - Flag-surface parity

    @Test("--gif-markers defaults to off on all three surfaces")
    func gifMarkersDefaultOff() throws {
        #expect(try RecordVideo.parse([]).gifMarkers == false)
        #expect(try IOSSimRecordVideoCommand.parse([]).gifMarkers == false)
        #expect(try AndroidRecordVideoCommand.parse([]).gifMarkers == false)
    }

    @Test("--gif-markers parses as true on all three surfaces")
    func gifMarkersParsesTrue() throws {
        #expect(try RecordVideo.parse(["--gif-markers"]).gifMarkers == true)
        #expect(try IOSSimRecordVideoCommand.parse(["--gif-markers"]).gifMarkers == true)
        #expect(try AndroidRecordVideoCommand.parse(["--gif-markers"]).gifMarkers == true)
    }

    // MARK: - Forwarding

    @Test("Top-level forwarder copies --gif-markers to the iOS subcommand")
    func gifMarkersForwardsToIOS() throws {
        let on = try RecordVideo.parse(["--gif-markers", "--udid", iosUDID])
        #expect(on.makeIOSSubcommand().gifMarkers == true)

        let off = try RecordVideo.parse(["--udid", iosUDID])
        #expect(off.makeIOSSubcommand().gifMarkers == false)
    }

    @Test("AndroidRecordVideoCommand.record requires gifMarkers in the forwarder's argument shape")
    func androidRecordContract() {
        let _: (
            String,
            String?,
            RecordingFormat?,
            Int?,
            Int,
            Double?,
            Bool
        ) async throws -> URL = AndroidRecordVideoCommand.record
    }
}
