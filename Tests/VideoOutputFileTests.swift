// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import SimUseVideo

/// Pins the `--output` path semantics every video-producing verb shares
/// (iOS + Android record-video, and the default filename shape agents
/// rely on). Pure filesystem logic — no device needed.
@Suite("VideoOutputFile — output path resolution")
struct VideoOutputFileTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-output-file-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("nil output defaults to a stamped mp4 in the current directory")
    func defaultName() throws {
        let url = try VideoOutputFile.prepareOutputURL(output: nil)
        #expect(url.lastPathComponent.hasPrefix("sim-use-video-"))
        #expect(url.pathExtension == "mp4")
        #expect(url.deletingLastPathComponent().path == FileManager.default.currentDirectoryPath)
    }

    @Test("empty / whitespace output falls back to the default name")
    func whitespaceOutput() throws {
        let url = try VideoOutputFile.prepareOutputURL(output: "   ")
        #expect(url.lastPathComponent.hasPrefix("sim-use-video-"))
    }

    @Test("absolute file path is used as-is")
    func absolutePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("clip.mp4")
        let url = try VideoOutputFile.prepareOutputURL(output: target.path)
        #expect(url.path == target.path)
    }

    @Test("intermediate directories are created for a nested file path")
    func createsIntermediateDirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("a/b/clip.mp4")
        let url = try VideoOutputFile.prepareOutputURL(output: target.path)
        #expect(url.path == target.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/b").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("an existing directory receives a stamped file inside it")
    func directoryTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try VideoOutputFile.prepareOutputURL(output: dir.path)
        #expect(url.deletingLastPathComponent().path == dir.path)
        #expect(url.lastPathComponent.hasPrefix("sim-use-video-"))
        #expect(url.pathExtension == "mp4")
    }

    @Test("an existing file at the target is replaced, not appended to")
    func existingFileReplaced() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("clip.mp4")
        try Data("stale".utf8).write(to: target)

        let url = try VideoOutputFile.prepareOutputURL(output: target.path)
        #expect(url.path == target.path)
        // prepareOutputURL removes the stale file so the recorder can
        // create it fresh.
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("tilde in the output path expands to the home directory")
    func tildeExpansion() throws {
        let name = "sim-use-tilde-test-\(UUID().uuidString).mp4"
        let url = try VideoOutputFile.prepareOutputURL(output: "~/\(name)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.path == NSHomeDirectory() + "/" + name)
    }
}
