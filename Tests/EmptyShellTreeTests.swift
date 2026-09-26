// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import FBControlCore
import Foundation
import Testing

// When a system document picker (or any remote-process presentation)
// owns the visible UI, the frontmost application's accessibility tree
// can come back as an empty shell — a bare AXApplication node with no
// frame and no children (issue #64). That shell is the trigger for the
// remote-content retry: it carries nothing for recovery or calibration
// to work from, so refetching with upstream's cross-process discovery
// is the only way to see the screen.
//
// `isEmptyShellTree` is the pure trigger decision: a payload is a
// shell iff no node in it carries a positive-area frame. Unrecognized
// shapes are NOT shells — failing closed keeps the retry (and its
// full-screen probe cost) off every path we don't understand.

@Suite("AccessibilityFetcher.isEmptyShellTree")
struct EmptyShellTreeTests {

    private func node(_ dict: [String: Any]) -> AnyObject { dict as AnyObject }
    private func nodes(_ array: [[String: Any]]) -> AnyObject { array as AnyObject }

    @Test("The 0.10.0-era shell — a bare AXApplication with no frame — is a shell")
    func bareApplicationIsShell() {
        let shell = nodes([["pid": 123, "role": "AXApplication"]])
        #expect(AccessibilityFetcher.isEmptyShellTree(shell))
    }

    @Test("The current-main shell — a full-screen-framed AXApplication with no children — is a shell")
    func framedChildlessApplicationIsShell() {
        // Captured live from a Safari + document-picker scene: the app
        // root DOES carry the screen-sized frame; only the content is
        // gone. The application container's own frame proves nothing
        // about visible content and must not veto the retry.
        let shell = nodes([[
            "AXFrame": "{{0, 0}, {402, 874}}",
            "AXLabel": "Safari浏览器",
            "children": [] as [[String: Any]],
            "enabled": true,
            "frame": ["height": 874, "width": 402, "x": 0, "y": 0],
            "pid": 5115,
            "role": "AXApplication",
            "role_description": "application",
            "type": "Application",
        ]])
        #expect(AccessibilityFetcher.isEmptyShellTree(shell))
    }

    @Test("An empty root array is a shell")
    func emptyArrayIsShell() {
        #expect(AccessibilityFetcher.isEmptyShellTree(nodes([])))
    }

    @Test("A framed non-application node is not a shell")
    func framedContentNodeIsNotShell() {
        let tree = nodes([[
            "role": "AXApplication",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            "children": [
                ["role": "AXWindow", "frame": ["x": 0, "y": 0, "width": 402, "height": 874]]
            ],
        ]])
        #expect(!AccessibilityFetcher.isEmptyShellTree(tree))
    }

    @Test("A frameless root whose child carries a frame is not a shell")
    func framedChildIsNotShell() {
        let tree = nodes([[
            "role": "AXApplication",
            "children": [
                ["role": "AXButton", "frame": ["x": 10, "y": 10, "width": 100, "height": 40]]
            ],
        ]])
        #expect(!AccessibilityFetcher.isEmptyShellTree(tree))
    }

    @Test("Zero-area frames do not rescue a shell")
    func zeroAreaFrameIsStillShell() {
        let tree = nodes([[
            "role": "AXApplication",
            "frame": ["x": 0, "y": 0, "width": 0, "height": 0],
            "children": [
                ["role": "AXGroup", "frame": ["x": 0, "y": 0, "width": 402, "height": 0]]
            ],
        ]])
        #expect(AccessibilityFetcher.isEmptyShellTree(tree))
    }

    @Test("A single-dictionary root follows the same rules")
    func singleDictionaryRoot() {
        #expect(AccessibilityFetcher.isEmptyShellTree(node(["pid": 5, "role": "AXApplication"])))
        #expect(!AccessibilityFetcher.isEmptyShellTree(node([
            "role": "AXButton",
            "frame": ["x": 0, "y": 0, "width": 100, "height": 100],
        ])))
    }

    @Test("Unrecognized payload shapes are not shells (fail closed)")
    func unrecognizedShapesAreNotShells() {
        #expect(!AccessibilityFetcher.isEmptyShellTree([1, 2, 3] as AnyObject))
        #expect(!AccessibilityFetcher.isEmptyShellTree("nonsense" as AnyObject))
    }
}

// The retry's grid points feed `translator.object(at:)`, which consumes
// UI-METRIC points on native-portrait AXES (issue #34 for the axes;
// `NativePortraitSize.uiMetric` for the metric) — but upstream's default
// sampling region is the root element's UI-space frame. Under rotation
// that region samples the wrong band: points past the portrait width hit
// nothing and a whole band is never sampled at all. The retry must
// therefore pass an explicit region in the hit-test canvas's portrait
// bounds — on a display-downscaled device that is the UI-sized canvas,
// not pixels/scale, or the right/bottom ~4% of the screen is never
// probed. The shell root's own full-screen frame supplies the UI size
// the scale needs, before any calibration has run.

@Suite("AccessibilityFetcher.remoteContentSamplingRegion")
struct RemoteContentSamplingRegionTests {

    @Test("The region is the native portrait bounds — orientation-independent")
    func regionIsNativePortraitBounds() {
        let region = AccessibilityFetcher.remoteContentSamplingRegion(
            native: NativePortraitSize(width: 1032, height: 1376))
        #expect(region == CGRect(x: 0, y: 0, width: 1032, height: 1376))
    }

    @Test("Unknown native size yields nil (upstream default region)")
    func unknownNativeYieldsNil() {
        #expect(AccessibilityFetcher.remoteContentSamplingRegion(native: nil) == nil)
    }

    @Test("A downscaled panel samples the UI-sized canvas, not pixels/scale")
    func downscaledRegionIsUISized() {
        // iPhone 12 mini: pixels/scale 360x780, UI 375x812. A 360x780
        // grid would leave the right/bottom ~4% unprobed.
        let mini = NativePortraitSize(width: 360, height: 780)
        let scale = UIPointScale(native: mini, uiPortrait: (width: 375, height: 812))!
        let region = AccessibilityFetcher.remoteContentSamplingRegion(native: mini, uiScale: scale)
        #expect(region == CGRect(x: 0, y: 0, width: 375, height: 812))
    }

    @Test("The scale is recoverable from the shell root's display frame")
    func scaleRecoveredFromShellRoot() {
        let mini = NativePortraitSize(width: 360, height: 780)
        // The current-runtimes shell shape: a full-screen-framed
        // AXApplication with no children (see the shell tests above).
        let framedShell = [[
            "frame": ["height": 812, "width": 375, "x": 0, "y": 0],
            "pid": 5115,
            "role": "AXApplication",
        ]] as AnyObject
        let scale = AccessibilityFetcher.uiScaleFromRawTree(framedShell, native: mini)
        #expect(!scale.isIdentity)
        #expect(
            AccessibilityFetcher.remoteContentSamplingRegion(native: mini, uiScale: scale)
                == CGRect(x: 0, y: 0, width: 375, height: 812)
        )

        // The 0.10.0-era bare shell has no frame to recover from —
        // identity keeps the pre-scale sampling behaviour.
        let bareShell = [["pid": 123, "role": "AXApplication"]] as AnyObject
        #expect(AccessibilityFetcher.uiScaleFromRawTree(bareShell, native: mini).isIdentity)
    }
}

// The retry request must NOT enable the frame-coverage grid. The grid
// is created and filled with UI-space frames while its isFilled gate
// consumes the retry's portrait-axes sample points — under rotation
// a discovered element's UI frame shadows a numerically-overlapping but
// visually unrelated portrait-axes band, skipping later sample points.
// And on the only path that runs discovery (an empty shell), the gate's
// upside is zero anyway: the grid starts empty, so it can never save a
// probe — it can only mis-skip one.

@Suite("LegacyAccessibilityRequestBuilder")
struct LegacyAccessibilityRequestBuilderTests {

    @Test("A plain fetch requests neither discovery nor the coverage grid")
    func plainFetchIsBare() {
        let options = LegacyAccessibilityRequestBuilder.options(
            nestedFormat: true, includeRemoteContent: false, remoteSamplingRegion: nil)
        #expect(options.nestedFormat)
        #expect(!options.collectFrameCoverage)
        #expect(options.remoteContentOptions == nil)
    }

    @Test("The remote retry samples the given region without the coverage grid")
    func retryHasRegionButNoGrid() {
        let region = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        let options = LegacyAccessibilityRequestBuilder.options(
            nestedFormat: true, includeRemoteContent: true, remoteSamplingRegion: region)
        #expect(!options.collectFrameCoverage)
        #expect(options.remoteContentOptions?.region == region)
    }

    @Test("A retry without a known region keeps upstream's default")
    func retryWithoutRegionUsesUpstreamDefault() {
        let options = LegacyAccessibilityRequestBuilder.options(
            nestedFormat: true, includeRemoteContent: true, remoteSamplingRegion: nil)
        #expect(!options.collectFrameCoverage)
        #expect(options.remoteContentOptions?.region.isNull == true)
    }
}
