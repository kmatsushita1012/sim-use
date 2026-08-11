// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Detects the Xcode-27-era `dtuhidd` daemon, which takes over the
/// simulator's HID keyboard service and silently drops the legacy
/// `SimDeviceLegacyHIDClient` keyboard path that `sim-use type` (and the
/// `key` family) rely on. When it is active, HID key injection is a no-op,
/// so callers fail loudly with a pointer to the `paste --via-menu`
/// workaround instead of typing into the void.
///
/// `dtuhidd` runs inside each booted simulator's `launchd_sim` domain, so we
/// scope detection to the target UDID by matching the daemon's parent
/// `launchd_sim` bootstrap path against the device UDID.
///
/// See facebook/idb "Detect when dtuhidd suppresses the legacy keyboard HID"
/// (2026-06). Tracking issue: Xcode 27 support
/// (github.com/lycorp-jp/sim-use/issues/84).
enum KeyboardHIDSuppression {
    /// Environment override: set to a non-empty value to skip the guard and
    /// attempt keyboard HID anyway.
    static let skipCheckEnvVar = "SIM_USE_SKIP_DTUHIDD_CHECK"

    /// True when a `dtuhidd` process is running inside the `launchd_sim`
    /// domain of the given simulator UDID. Returns false (fail open) when the
    /// process table cannot be read.
    static func isSuppressed(forUDID udid: String) -> Bool {
        guard let table = processTable() else { return false }

        // launchd_sim PIDs whose bootstrap path names this UDID.
        let simBootstrapPIDs = Set(
            table
                .filter { $0.command.contains("launchd_sim") && $0.command.contains(udid) }
                .map(\.pid)
        )
        guard !simBootstrapPIDs.isEmpty else { return false }

        return table.contains { process in
            isDtuhidd(process.command) && simBootstrapPIDs.contains(process.ppid)
        }
    }

    /// Actionable message describing the suppression and how to recover.
    static func workaroundMessage(udid: String) -> String {
        """
        Keyboard HID is suppressed by dtuhidd (Xcode 27 / new Simulator runtime).
        `type` is a silent no-op while dtuhidd is active (Device Hub open, or a
        CoreDevice HID client attached): the legacy keyboard HID path is disconnected.

        Fixes, in order of preference:
          1. Quit Device Hub, then re-boot the simulator. A fresh boot with no
             CoreDevice HID client reconnects the legacy keyboard and `type` works
             (verified on iOS 27). A live re-boot is required - the legacy service
             is disconnected at boot, so closing Device Hub alone is not enough:
               Shut down and boot \(udid) again from Simulator.app or your
               normal Simulator management tooling.
             (A headless boot is sufficient; opening Simulator.app shows the window -
             the classic Simulator.app does not trigger dtuhidd, only Device Hub does.)
          2. Or use the touch-driven pasteboard path (bypasses keyboard HID):
               sim-use tap <target> --udid \(udid)
               sim-use paste "<text>" --via-menu --target-id <AXUniqueId> --udid \(udid)

        Set \(skipCheckEnvVar)=1 to attempt typing anyway.
        """
    }

    private static func isDtuhidd(_ command: String) -> Bool {
        command == "dtuhidd"
            || command.hasSuffix("/dtuhidd")
            || command.hasPrefix("/usr/libexec/dtuhidd")
    }

    private struct ProcessEntry {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    private static func processTable() -> [ProcessEntry]? {
        // libproc/sysctl gives us the same process metadata without forking
        // the host's `ps` command. `KERN_PROCARGS2` is used because the
        // simulator UDID is part of launchd_sim's argv, not its executable
        // name.
        let reportedCount = proc_listallpids(nil, 0)
        guard reportedCount > 0 else { return nil }

        var pids = [pid_t](repeating: 0, count: Int(reportedCount))
        let writtenCount = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard writtenCount > 0 else { return nil }

        return pids.prefix(Int(writtenCount)).compactMap { pid in
            processEntry(pid: pid)
        }
    }

    private static func processEntry(pid: pid_t) -> ProcessEntry? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
            return nil
        }

        let path = processPath(pid: pid)
        let arguments = processArguments(pid: pid)
        let command = ([path] + arguments.dropFirst()).joined(separator: " ")
        guard !command.isEmpty else { return nil }
        return ProcessEntry(pid: pid, ppid: Int32(info.pbi_ppid), command: command)
    }

    private static func processPath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func processArguments(pid: pid_t) -> [String] {
        var mib = [Int32](arrayLiteral: Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid)
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
        }) == 0 else {
            return []
        }

        let argc = Int(buffer[0])
            | (Int(buffer[1]) << 8)
            | (Int(buffer[2]) << 16)
            | (Int(buffer[3]) << 24)
        guard argc > 0 else { return [] }
        return buffer.dropFirst(4)
            .split(separator: 0, omittingEmptySubsequences: true)
            .prefix(argc)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
