// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// SIM_USE_DEBUG=1 is the diagnostics switch for issue #67: it must
// reach every logger construction path (including call sites that
// pass their own flags, like `ios batch --verbose`), and it follows
// the SIM_USE_NO_DAEMON convention of matching the literal "1" only.

@Suite("SimUseLogger.debugEnvironmentEnabled")
struct SimUseLoggerDebugEnvironmentTests {

    @Test("The literal value 1 enables debug output")
    func literalOneEnables() {
        #expect(SimUseLogger.debugEnvironmentEnabled(["SIM_USE_DEBUG": "1"]))
    }

    @Test("Any other value is ignored")
    func otherValuesAreIgnored() {
        #expect(!SimUseLogger.debugEnvironmentEnabled(["SIM_USE_DEBUG": "0"]))
        #expect(!SimUseLogger.debugEnvironmentEnabled(["SIM_USE_DEBUG": "true"]))
        #expect(!SimUseLogger.debugEnvironmentEnabled(["SIM_USE_DEBUG": ""]))
    }

    @Test("An unset variable leaves debug output off")
    func unsetIsOff() {
        #expect(!SimUseLogger.debugEnvironmentEnabled([:]))
    }
}
