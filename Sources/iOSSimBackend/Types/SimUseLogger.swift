// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore

public final class SimUseLogger: FBCompositeLogger {
    public override init(loggers: [FBControlCoreLogger]) {
        super.init(loggers: loggers)
    }
    
    /// SIM_USE_DEBUG=1 forces stderr and debug-level output on every
    /// logger regardless of what the call site asked for (OR-merged
    /// below), so info-lines like the HID transport-selection signals
    /// become visible in the field (issue #67) — including call sites
    /// that pass their own flags, like `ios batch --verbose`. The
    /// daemon redirects stderr to its logfile but keeps the
    /// environment it was spawned with — combine with a daemon
    /// restart or SIM_USE_NO_DAEMON=1.
    static func debugEnvironmentEnabled(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["SIM_USE_DEBUG"] == "1"
    }

    public convenience init(debugLogging: Bool = false, writeToStdErr: Bool = true) {
        let debug = Self.debugEnvironmentEnabled()
        let systemLogger = FBControlCoreLoggerFactory.systemLoggerWriting(
            toStderr: writeToStdErr || debug,
            withDebugLogging: debugLogging || debug
        )
        self.init(loggers: [systemLogger])
    }

    /// The default logger writes to no visible sink unless
    /// SIM_USE_DEBUG=1 turns one on (see `debugEnvironmentEnabled`).
    public override convenience init() {
        self.init(debugLogging: false, writeToStdErr: false)
    }
    
    public func makeDefault() {
        FBControlCoreGlobalConfiguration.defaultLogger = self
    }
    
    public func warning() -> FBControlCoreLogger {
        return self.debug()
    }
}