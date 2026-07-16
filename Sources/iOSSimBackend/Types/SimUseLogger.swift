// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore

public final class SimUseLogger: FBCompositeLogger {
    public override init(loggers: [FBControlCoreLogger]) {
        super.init(loggers: loggers)
    }
    
    public convenience init(debugLogging: Bool = false, writeToStdErr: Bool = true) {
        let systemLogger = FBControlCoreLoggerFactory.systemLoggerWriting(
            toStderr: writeToStdErr,
            withDebugLogging: debugLogging
        )
        self.init(loggers: [systemLogger])
    }

    /// Logger for application-facing APIs. The caller receives failures as
    /// thrown errors, so routine backend progress should not be written to
    /// the host application's console.
    public convenience init(silent: Bool) {
        if silent {
            self.init(loggers: [])
        } else {
            self.init()
        }
    }
    
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
