// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Output-path resolution shared by every video-producing verb,
/// regardless of platform backend.
public enum VideoOutputFile {
    /// Resolve the user-supplied `--output` argument into a concrete
    /// output file URL (default naming uses `fileExtension`). Every
    /// platform backend and the cross-platform forwarder use the same
    /// path semantics (`OutputFilePath`).
    public static func prepareOutputURL(output: String?, fileExtension: String = "mp4") throws -> URL {
        let url = OutputFilePath.resolve(output: output) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return "sim-use-video-\(formatter.string(from: Date())).\(fileExtension)"
        }
        try OutputFilePath.prepare(url)
        return url
    }
}
