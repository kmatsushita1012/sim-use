// SPDX-License-Identifier: Apache-2.0
//
//  MapTestView.swift
//  SimUsePlayground
//

import MapKit
import SwiftUI

/// A visual target for repeated HID touch-down experiments.
///
/// The map itself receives the injected touch events. The status panel is
/// intentionally non-interactive so it cannot steal the gesture. MapKit's
/// camera callback exposes whether the map actually moved in response to
/// the Down/Down/Down/Up sequence.
struct MapTestView: View {
    private static let initialRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    @State private var cameraPosition: MapCameraPosition = .region(Self.initialRegion)
    @State private var cameraChangeCount = 0
    @State private var lastCenter = Self.initialRegion.center

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                Marker("Tokyo Station", coordinate: Self.initialRegion.center)
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                cameraChangeCount += 1
                lastCenter = context.region.center
            }

            VStack(spacing: 8) {
                Text("Repeated Down Map Test")
                    .font(.headline)

                Text("Drag the map with repeated touchDownAt events")
                    .font(.caption)

                Text("Camera updates: \(cameraChangeCount)")
                    .font(.caption.monospacedDigit())

                Text(String(format: "Center: %.5f, %.5f", lastCenter.latitude, lastCenter.longitude))
                    .font(.caption2.monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding(.top, 12)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("Map Touch Test")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("map-touch-test-screen")
        .accessibilityValue(String(format: "camera updates:%d;center:%.5f,%.5f", cameraChangeCount, lastCenter.latitude, lastCenter.longitude))
    }
}

#Preview {
    NavigationStack {
        MapTestView()
    }
}
