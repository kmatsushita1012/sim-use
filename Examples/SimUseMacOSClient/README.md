# SimUseKit macOS client example

This is a standalone SwiftPM executable that depends on the repository as a
local package and imports only `SimUseKit`.

```bash
cd Examples/SimUseMacOSClient
swift run SimUseMacOSClient <booted-simulator-udid>
```

The example performs `describe-ui`, opens a reusable HID session, and sends a
single-session touch sequence. It requires the same generated idb
XCFrameworks and Xcode/private-framework environment as the main package.
