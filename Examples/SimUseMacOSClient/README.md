# SimUseKit macOS client example

This is a standalone SwiftPM executable that depends on the repository as a
local package and imports only `SimUseKit`.

```bash
../../scripts/build.sh dev
cd Examples/SimUseMacOSClient
swift run SimUseMacOSClient <booted-simulator-udid>
```

The example performs `describe-ui`, opens a reusable HID session, and sends a
single-session touch sequence. `build.sh dev` generates the static idb
XCFrameworks and private-framework module maps; this sample package supplies
the required compile-time module-map flags automatically.
