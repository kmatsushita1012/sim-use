// SPDX-License-Identifier: Apache-2.0
import FBControlCore
import Foundation

/// The simulator's native screen size in points — the coordinate space the
/// HID layer normalizes against (`FBSimulatorIndigoHID` divides by
/// `deviceType.mainScreenSize` pixels). AX point hit-tests share these
/// AXES (native portrait) but not the metric — see
/// ``NativePortraitSize/uiMetric(_:)``. iOS devices report this
/// portrait-major.
public struct NativePortraitSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Points = pixels / scale, matching the HID layer's own math
    /// (`FBSimulatorIndigoHID.screenRatioFromPoint:` multiplies points by
    /// scale before dividing by pixel size). `nil` when the target has no
    /// screen info or reports degenerate values.
    public init?(screenInfo: FBiOSTargetScreenInfo?) {
        guard let screenInfo, screenInfo.scale > 0,
              screenInfo.widthPixels > 0, screenInfo.heightPixels > 0
        else { return nil }
        self.width = Double(screenInfo.widthPixels) / Double(screenInfo.scale)
        self.height = Double(screenInfo.heightPixels) / Double(screenInfo.scale)
    }

    /// The same portrait rectangle expressed in the UI point metric —
    /// the canvas AX point hit-tests are interpreted on. The hit-test
    /// XPC shares HID's native-portrait axes but consumes UI-metric
    /// points (verified live on iPhone 12 mini / iOS 26.4: the un-scaled
    /// UI point returns the element at that point; the pixels/scale-
    /// shrunk point lands ~4% off). Identity scale returns `self`, so
    /// devices that render 1:1 are untouched.
    public func uiMetric(_ scale: UIPointScale) -> NativePortraitSize {
        scale.isIdentity
            ? self
            : NativePortraitSize(width: width / scale.x, height: height / scale.y)
    }
}

/// Multipliers that carry a UI point into the native framebuffer point
/// space, expressed on the portrait-major axes.
///
/// Both are 1 whenever a device renders at its panel resolution, which is
/// why the two spaces were treated as one until now. Display-downscaled
/// models break that: iPhone 12/13 mini lay out 375x812 points and render
/// 1125x2436, then downsample onto a 1080x2340 panel, so
/// ``NativePortraitSize`` reads 360x780 and every AX coordinate has to
/// shrink by 0.96 before HID can consume it. The 6/6s/7/8 Plus family
/// (1242x2208 rendered, 1080x1920 panel) behaves the same way.
public struct UIPointScale: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public static let identity = UIPointScale(x: 1, y: 1)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// `nil` when the UI size is degenerate. `uiPortrait` must be
    /// portrait-major, like ``NativePortraitSize``.
    public init?(native: NativePortraitSize, uiPortrait: (width: Double, height: Double)) {
        guard uiPortrait.width > 0, uiPortrait.height > 0 else { return nil }
        self.init(x: native.width / uiPortrait.width, y: native.height / uiPortrait.height)
    }

    /// Tolerant against the rounding of a pixels/scale division rather
    /// than exact, so a device that merely fails to divide evenly does
    /// not pay for a transform.
    public var isIdentity: Bool { abs(x - 1) < 1e-6 && abs(y - 1) < 1e-6 }
}

/// The app's interface orientation relative to the native framebuffer.
///
/// AX element frames arrive in the app UI space (they rotate with the
/// interface); HID taps and AX point hit-tests are interpreted on the
/// fixed native-portrait AXES — though in different metrics: HID
/// normalizes against pixels/scale while the hit-test keeps the UI
/// point metric (identical on 1:1 devices; see
/// ``NativePortraitSize/uiMetric(_:)``). These are the four possible
/// axis mappings, measured empirically on iOS 26.5 (issue #34) with
/// portrait W×H points and portrait-axis point `f` ↔ UI point `u`:
///
///     portrait             u = f
///     portraitUpsideDown   u = (W−fx, H−fy)
///     landscapeRight       u = (fy, W−fx)      f = (W−uy, ux)
///     landscapeLeft        u = (H−fy, fx)      f = (uy, H−ux)
///
/// Names follow CoreSimulator's display descriptor (`simctl io enumerate`
/// "UI Orientation"), verified live against each Simulator rotate state:
/// one rotate-left from upright is Landscape Right, one rotate-right is
/// Landscape Left.
///
/// Those mappings assume the two spaces share one metric. On a
/// display-downscaled device they do not, so every conversion also takes a
/// ``UIPointScale``.
public enum DisplayOrientation: String, CaseIterable, Codable, Sendable {
    case portrait = "portrait"
    case portraitUpsideDown = "portrait-upside-down"
    case landscapeRight = "landscape-right"
    case landscapeLeft = "landscape-left"

    public var swapsDimensions: Bool {
        switch self {
        case .portrait, .portraitUpsideDown: return false
        case .landscapeRight, .landscapeLeft: return true
        }
    }

    /// The UI-space screen size for this orientation.
    public func uiSize(
        native: NativePortraitSize,
        uiScale: UIPointScale = .identity
    ) -> (width: Double, height: Double) {
        let width = native.width / uiScale.x
        let height = native.height / uiScale.y
        return swapsDimensions ? (width: height, height: width) : (width: width, height: height)
    }

    /// Framebuffer point → UI point.
    public func framebufferToUI(
        _ p: CGPoint,
        native: NativePortraitSize,
        uiScale: UIPointScale = .identity
    ) -> CGPoint {
        let w = native.width
        let h = native.height
        let mapped: CGPoint
        switch self {
        case .portrait:
            mapped = p
        case .portraitUpsideDown:
            mapped = CGPoint(x: w - p.x, y: h - p.y)
        case .landscapeRight:
            mapped = CGPoint(x: p.y, y: w - p.x)
        case .landscapeLeft:
            mapped = CGPoint(x: h - p.y, y: p.x)
        }
        let ui = uiSize(native: native, uiScale: uiScale)
        return clamp(intoUIMetric(mapped, uiScale: uiScale), width: ui.width, height: ui.height)
    }

    /// UI point → native-portrait axes. With the calibrated `uiScale`,
    /// this is the coordinate to hand to HID; a point hit-test instead
    /// takes the identity scale on the UI-sized canvas (see
    /// `OrientationCalibration.probeCGPoint`) because it keeps the UI
    /// metric.
    public func uiToFramebuffer(
        _ p: CGPoint,
        native: NativePortraitSize,
        uiScale: UIPointScale = .identity
    ) -> CGPoint {
        let w = native.width
        let h = native.height
        let q = intoNativeMetric(p, uiScale: uiScale)
        let mapped: CGPoint
        switch self {
        case .portrait:
            mapped = q
        case .portraitUpsideDown:
            mapped = CGPoint(x: w - q.x, y: h - q.y)
        case .landscapeRight:
            mapped = CGPoint(x: w - q.y, y: q.x)
        case .landscapeLeft:
            mapped = CGPoint(x: q.y, y: h - q.x)
        }
        return clamp(mapped, width: w, height: h)
    }

    /// The scale is portrait-major while these points are on UI axes, and
    /// landscape runs the UI x axis along the native y axis — so the two
    /// factors swap with the dimensions.
    private func intoNativeMetric(_ p: CGPoint, uiScale: UIPointScale) -> CGPoint {
        swapsDimensions
            ? CGPoint(x: p.x * uiScale.y, y: p.y * uiScale.x)
            : CGPoint(x: p.x * uiScale.x, y: p.y * uiScale.y)
    }

    private func intoUIMetric(_ p: CGPoint, uiScale: UIPointScale) -> CGPoint {
        swapsDimensions
            ? CGPoint(x: p.x / uiScale.y, y: p.y / uiScale.x)
            : CGPoint(x: p.x / uiScale.x, y: p.y / uiScale.y)
    }

    /// The 180° image of an on-screen edge point lands exactly on W (or
    /// H), one point past the addressable range — hit-tests there return
    /// nil and HID would tap off-screen. Clamp to the half-open range
    /// [0, limit) so edge elements stay reachable.
    private func clamp(_ p: CGPoint, width: Double, height: Double) -> CGPoint {
        CGPoint(
            x: min(max(p.x, 0), width.nextDown),
            y: min(max(p.y, 0), height.nextDown)
        )
    }
}
