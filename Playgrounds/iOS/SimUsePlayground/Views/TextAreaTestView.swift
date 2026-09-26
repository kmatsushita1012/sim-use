// SPDX-License-Identifier: Apache-2.0
//
//  TextAreaTestView.swift
//  SimUsePlayground
//

import SwiftUI

// MARK: - Text Area View
//
// Multi-line editor fixture. SwiftUI's TextEditor surfaces in the
// accessibility tree as role "TextArea" (unlike TextField's "TextField"),
// the shape of real-world chat message inputs — the regression surface
// for the outline omitting a TextArea's value.
struct TextAreaTestView: View {
    @State private var editorText = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Text Area Playground")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("text-area-title")
                Text("Type into the multi-line editor")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("text-area-description")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)

            TextEditor(text: $editorText)
                .font(.title3)
                .frame(height: 160)
                .focused($isEditorFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                )
                .accessibilityIdentifier("text-area-field")
                // A non-empty AX label mirrors real-world message inputs
                // (e.g. LINE's chat field). With it, the outline can no
                // longer fall back to showing the value as the label, so
                // the typed text is invisible unless value= is rendered.
                .accessibilityLabel("Message editor")

            if !editorText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Characters: \(editorText.count)")
                        .accessibilityIdentifier("text-area-character-count")
                        .accessibilityValue("\(editorText.count)")
                    Text("Lines: \(editorText.split(separator: "\n", omittingEmptySubsequences: false).count)")
                        .accessibilityIdentifier("text-area-line-count")
                        .accessibilityValue("\(editorText.split(separator: "\n", omittingEmptySubsequences: false).count)")
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Text Area")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isEditorFocused = true
        }
    }
}
