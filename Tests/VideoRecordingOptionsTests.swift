// SPDX-License-Identifier: Apache-2.0
import Testing
import SimUseVideo

/// Boundary pins for the shared record/stream flag validators — the one
/// place the cross-platform flag contract lives (#78).
@Suite("VideoRecordingOptions — flag validation")
struct VideoRecordingOptionsTests {
    @Test("recording accepts the documented ranges")
    func recordingAccepts() throws {
        try VideoRecordingOptions.validate(fps: nil, quality: 80, scale: 1.0)
        try VideoRecordingOptions.validate(fps: 1, quality: 1, scale: 0.1)
        try VideoRecordingOptions.validate(fps: 60, quality: 100, scale: 1.0)
    }

    @Test("recording rejects out-of-range values")
    func recordingRejects() {
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validate(fps: 0, quality: 80, scale: 1.0) }
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validate(fps: 61, quality: 80, scale: 1.0) }
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validate(fps: nil, quality: 0, scale: 1.0) }
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validate(fps: nil, quality: 101, scale: 1.0) }
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validate(fps: nil, quality: 80, scale: 0.05) }
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validate(fps: nil, quality: 80, scale: 1.01) }
    }

    @Test("streaming caps FPS at 30 where recording allows 60")
    func streamingFPSCap() throws {
        try VideoRecordingOptions.validateStreaming(fps: 30, quality: 80, scale: 1.0)
        try VideoRecordingOptions.validateStreaming(fps: nil, quality: 80, scale: 1.0)
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validateStreaming(fps: 31, quality: 80, scale: 1.0) }
        #expect(throws: (any Error).self) { try VideoRecordingOptions.validateStreaming(fps: 0, quality: 80, scale: 1.0) }
    }
}
