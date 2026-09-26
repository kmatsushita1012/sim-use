// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// The HID connection cache is only valid for the boot instance it was
// created against: a simulator shut down and re-booted under the same
// UDID passes the `state == .booted` re-check while the cached mach
// port is dead — and the send against it either hangs (Xcode 26.5 /
// iOS 26.2) or reports success without delivering (issue #55,
// Xcode 27 B4 / CoreSimulator 1169.1), so no error ever reaches the
// failure-classification path.
//
// `HIDBootIdentity` therefore gates cache reuse on a compound boot
// token: the `launchd_sim` process identity (authoritative) with the
// `launchd_bootstrap.plist` mtime as fallback. Pure decision +
// filesystem probe are tested here without FB* types.

@Suite("HIDBootIdentity.isReusable")
struct HIDBootIdentityReusableTests {
    private let bootA = Date(timeIntervalSince1970: 1_782_991_697)
    private let bootB = Date(timeIntervalSince1970: 1_782_995_000)
    private let simA = LaunchdSimIdentity(pid: 74691, startedAt: Date(timeIntervalSince1970: 1_784_773_778))
    private let simB = LaunchdSimIdentity(pid: 79469, startedAt: Date(timeIntervalSince1970: 1_784_773_859))

    private func token(_ sim: LaunchdSimIdentity?, _ marker: Date?) -> HIDBootToken {
        HIDBootToken(launchdSim: sim, markerModificationDate: marker)
    }

    @Test("Same launchd_sim identity on both sides allows reuse")
    func sameLaunchdSimIdentityReuses() {
        #expect(HIDBootIdentity.isReusable(cachedToken: token(simA, bootA), currentToken: token(simA, bootA)))
    }

    @Test("A changed launchd_sim pid (reboot) rejects reuse")
    func changedLaunchdSimPidRejects() {
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(simA, bootA), currentToken: token(simB, bootA)))
    }

    @Test("Same pid with a different start time (pid reuse) rejects reuse")
    func samePidDifferentStartTimeRejects() {
        let recycled = LaunchdSimIdentity(pid: simA.pid, startedAt: simA.startedAt.addingTimeInterval(120))
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(simA, bootA), currentToken: token(recycled, bootA)))
    }

    @Test("Process identity is authoritative: equal identity reuses even when the marker moved")
    func launchdSimEqualButMarkerChangedStillReuses() {
        // A marker rewritten mid-boot (or with sub-second stat jitter)
        // must not evict a live connection while launchd_sim proves the
        // boot is unchanged.
        #expect(HIDBootIdentity.isReusable(cachedToken: token(simA, bootA), currentToken: token(simA, bootB)))
    }

    @Test("Process identity is authoritative: equal marker with a changed identity rejects")
    func markerEqualButLaunchdSimChangedRejects() {
        // The issue #55 regression row: CoreSimulator skipped the
        // marker rewrite across a reboot, the mtimes compared equal,
        // and the dead connection was judged reusable. The process
        // identity must override the stale-equal marker.
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(simA, bootA), currentToken: token(simB, bootA)))
    }

    @Test("A one-sided launchd_sim identity rejects reuse")
    func oneSidedLaunchdSimIdentityRejects() {
        // Probe visible on one side only: the boot cannot be proven
        // unchanged. Failing closed costs one rebuild (~ms); failing
        // open risks a dead port that hangs or silently drops input.
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(nil, bootA), currentToken: token(simA, bootA)))
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(simA, bootA), currentToken: token(nil, bootA)))
    }

    @Test("Without process identities, equal markers allow reuse")
    func bothProbesUnavailableFallsBackToMarkerEqual() {
        #expect(HIDBootIdentity.isReusable(cachedToken: token(nil, bootA), currentToken: token(nil, bootA)))
    }

    @Test("Without process identities, a changed marker rejects reuse")
    func bothProbesUnavailableMarkerChangedRejects() {
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(nil, bootA), currentToken: token(nil, bootB)))
    }

    @Test("Fully unknown tokens reject reuse")
    func unknownTokensReject() {
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(nil, nil), currentToken: token(nil, nil)))
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(nil, nil), currentToken: token(nil, bootA)))
        #expect(!HIDBootIdentity.isReusable(cachedToken: token(nil, bootA), currentToken: token(nil, nil)))
        #expect(!HIDBootIdentity.isReusable(cachedToken: nil, currentToken: token(simA, bootA)))
    }
}

// Upstream's HID transport auto-selection probes the simulator's
// process tree for dtuhidd at `FBSimulatorHID` construction — but
// dtuhidd attaches 0–3 s *after* boot on a simulator booted while
// Device Hub is open (issue #67). A selection made inside that window
// resolves to Indigo on a dtuhidd-suppressed simulator and, once
// cached, silently pins the dead transport for the whole boot (Indigo
// reports success without delivering, so recovery never fires).
// `isTransportSelectionTrustworthy` gates the cache: a connection
// built inside the window may be used once but must not be reused.

@Suite("HIDBootIdentity.isTransportSelectionTrustworthy")
struct HIDTransportTrustWindowTests {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func token(uptime: TimeInterval?) -> HIDBootToken {
        HIDBootToken(
            launchdSim: uptime.map { LaunchdSimIdentity(pid: 74691, startedAt: now.addingTimeInterval(-$0)) },
            markerModificationDate: nil
        )
    }

    @Test("A selection made inside the boot-attach window is not trustworthy")
    func insideWindowIsNotTrustworthy() {
        // dtuhidd was measured attaching 0–3 s after launchd_sim; the
        // window leaves margin over that. Anything probed before the
        // boundary may have raced the attach.
        #expect(!HIDBootIdentity.isTransportSelectionTrustworthy(token: token(uptime: 2), now: now))
        #expect(!HIDBootIdentity.isTransportSelectionTrustworthy(token: token(uptime: 14.9), now: now))
    }

    @Test("A selection at or past the window boundary is trustworthy")
    func atOrPastWindowIsTrustworthy() {
        #expect(HIDBootIdentity.isTransportSelectionTrustworthy(
            token: token(uptime: HIDBootIdentity.transportTrustWindow), now: now))
        #expect(HIDBootIdentity.isTransportSelectionTrustworthy(token: token(uptime: 300), now: now))
    }

    @Test("Unknown launchd_sim identity keeps the marker-fallback caching behavior")
    func unknownIdentityIsTrustworthy() {
        // The race evidence only exists where the launchd_sim probe
        // works; failing closed here would rebuild the connection on
        // every command in environments where the probe never works.
        #expect(HIDBootIdentity.isTransportSelectionTrustworthy(token: token(uptime: nil), now: now))
    }

    @Test("A start time in the future (clock anomaly) is not trustworthy")
    func futureStartTimeIsNotTrustworthy() {
        #expect(!HIDBootIdentity.isTransportSelectionTrustworthy(token: token(uptime: -30), now: now))
    }
}

@Suite("HIDBootIdentity.token")
struct HIDBootIdentityTokenTests {

    private func makeTempDataDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HIDBootIdentityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("var/run"),
            withIntermediateDirectories: true
        )
        return root
    }

    @Test("Token composes the injected probe with the marker mtime")
    func tokenComposesProbeAndMarker() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let marker = dataDirectory.appendingPathComponent("var/run/launchd_bootstrap.plist")
        FileManager.default.createFile(atPath: marker.path, contents: Data("boot".utf8))
        let identity = LaunchdSimIdentity(pid: 42, startedAt: Date(timeIntervalSince1970: 1_784_773_778))

        var probedUDID: String?
        let token = HIDBootIdentity.token(
            dataDirectory: dataDirectory.path,
            udid: "TEST-UDID",
            launchdSimProbe: { udid in
                probedUDID = udid
                return identity
            }
        )

        let expectedMarker = try FileManager.default
            .attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        #expect(probedUDID == "TEST-UDID")
        #expect(token.launchdSim == identity)
        #expect(token.markerModificationDate == expectedMarker)
    }

    @Test("Marker probe reads the boot marker's modification date")
    func markerProbeReadsMtime() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let marker = dataDirectory.appendingPathComponent("var/run/launchd_bootstrap.plist")
        FileManager.default.createFile(atPath: marker.path, contents: Data("boot".utf8))

        let mtime = HIDBootIdentity.markerModificationDate(dataDirectory: dataDirectory.path)
        let expected = try FileManager.default
            .attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        #expect(mtime != nil)
        #expect(mtime == expected)
    }

    @Test("Rewriting the marker (a new boot) changes the marker probe")
    func rewrittenMarkerChangesMtime() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let marker = dataDirectory.appendingPathComponent("var/run/launchd_bootstrap.plist")
        FileManager.default.createFile(atPath: marker.path, contents: Data("boot-1".utf8))
        let first = HIDBootIdentity.markerModificationDate(dataDirectory: dataDirectory.path)

        // Simulate the next boot rewriting the marker some time later.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: marker.path
        )
        let second = HIDBootIdentity.markerModificationDate(dataDirectory: dataDirectory.path)

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    @Test("Missing marker file yields nil")
    func missingMarkerIsNil() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        #expect(HIDBootIdentity.markerModificationDate(dataDirectory: dataDirectory.path) == nil)
    }

    @Test("Nil data directory yields nil")
    func nilDataDirectoryIsNil() {
        #expect(HIDBootIdentity.markerModificationDate(dataDirectory: nil) == nil)
    }
}
