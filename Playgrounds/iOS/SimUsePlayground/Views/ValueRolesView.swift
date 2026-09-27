// SPDX-License-Identifier: Apache-2.0
//
//  ValueRolesView.swift
//  SimUsePlayground
//

import SwiftUI

// MARK: - Value Roles View
//
// One control per AX role that carries an AXValue distinct from its
// label. Ground-truth fixture for which roles the describe-ui outline
// should render `value=` for — the AX bridge's role vocabulary is
// empirical, so probe here before extending the whitelist.
struct ValueRolesView: View {
    @State private var sliderValue = 0.4
    @State private var stepperValue = 3
    @State private var pickerSelection = "Beta"
    @State private var toggleOn = true
    @State private var birthday = Date(timeIntervalSince1970: 1_000_000_000)

    private let pickerOptions = ["Alpha", "Beta", "Gamma"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Slider(value: $sliderValue) {
                    Text("Volume")
                }
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("value-roles-slider")

                Stepper("Quantity", value: $stepperValue, in: 0...10)
                    .accessibilityIdentifier("value-roles-stepper")

                ProgressView(value: 0.7) {
                    Text("Download")
                }
                .accessibilityIdentifier("value-roles-progress")

                ProgressView()
                    .accessibilityLabel("Loading")
                    .accessibilityIdentifier("value-roles-activity")

                Toggle("Notifications", isOn: $toggleOn)
                    .accessibilityIdentifier("value-roles-toggle")

                Picker("Channel", selection: $pickerSelection) {
                    ForEach(pickerOptions, id: \.self) { Text($0) }
                }
                .pickerStyle(.wheel)
                .frame(height: 120)
                .accessibilityIdentifier("value-roles-picker")

                Picker("Mode", selection: $pickerSelection) {
                    ForEach(pickerOptions, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("value-roles-segmented")

                DatePicker("Birthday", selection: $birthday, displayedComponents: .date)
                    .accessibilityIdentifier("value-roles-datepicker")

                TabView {
                    Text("Page One").tag(0)
                    Text("Page Two").tag(1)
                    Text("Page Three").tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(height: 80)
                .accessibilityIdentifier("value-roles-pages")

                Text("UIKit")
                    .font(.headline)

                UIKitValueRoles()
                    .frame(height: 420)
            }
            .padding()
        }
        .navigationTitle("Value Roles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// UIKit counterparts — most production apps (e.g. LINE) are UIKit, and
// the AX bridge maps UIKit controls to different roles than SwiftUI
// (UITextView → TextArea, UIPageControl → PageIndicator, ...).
private struct UIKitValueRoles: UIViewRepresentable {
    func makeUIView(context: Context) -> UIStackView {
        let searchBar = UISearchBar()
        searchBar.text = "query text"
        searchBar.accessibilityIdentifier = "uikit-search-bar"

        let textView = UITextView()
        textView.text = "uikit textview content"
        textView.accessibilityLabel = "Notes editor"
        textView.accessibilityIdentifier = "uikit-text-view"
        textView.layer.borderWidth = 1
        textView.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let slider = UISlider()
        slider.value = 0.4
        slider.accessibilityLabel = "Brightness"
        slider.accessibilityIdentifier = "uikit-slider"

        let stepper = UIStepper()
        stepper.value = 3
        stepper.accessibilityLabel = "Copies"
        stepper.accessibilityIdentifier = "uikit-stepper"

        let pageControl = UIPageControl()
        pageControl.numberOfPages = 3
        pageControl.currentPage = 1
        pageControl.accessibilityIdentifier = "uikit-page-control"
        pageControl.backgroundColor = .systemGray5

        let progress = UIProgressView(progressViewStyle: .default)
        progress.progress = 0.7
        progress.accessibilityLabel = "Upload"
        progress.accessibilityIdentifier = "uikit-progress"

        let uiSwitch = UISwitch()
        uiSwitch.isOn = false
        uiSwitch.accessibilityLabel = "Airplane Mode"
        uiSwitch.accessibilityIdentifier = "uikit-switch"

        let datePicker = UIDatePicker()
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.date = Date(timeIntervalSince1970: 1_000_000_000)
        datePicker.accessibilityIdentifier = "uikit-date-picker"
        datePicker.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            searchBar, textView, slider, stepper, pageControl, progress, uiSwitch, datePicker,
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {}
}
