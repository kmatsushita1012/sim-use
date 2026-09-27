# Development Rules

## Code quality
- No `Any` types unless absolutely necessary; upgrade dependencies rather than downgrading code to work around type errors.
- Follow Swift best practices and match the style of surrounding code.
- When adding or removing commands/options, update the README and `skills/sim-use/SKILL.md`.

## Public SimUseKit API verification
- Any type used by a public `SimUseKit` request, result, or application-facing example must be explicitly public and reachable with `import SimUseKit` alone.
- Do not verify public API visibility only from inside `SimUseKit` or an implementation target. Add a test that imports only `SimUseKit` and directly names every newly exposed type, including enums such as `GesturePreset`.
- Before reporting completion, compile and run the public API test target. If the consuming macOS app is available, also build that target to catch package import and module-cache issues.
- Prefer explicit public facade declarations or typealiases in `Sources/SimUseKit/Exports.swift` for shared implementation types that form part of the application API.

## Changelog
`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Add entries under `## [Unreleased]` as you land changes. Subsection order: `### Added` / `### Changed` / `### Fixed` / `### Removed`. Never modify already-released version sections.

## Build and test

### First-time setup

```bash
brew install xcodegen    # idb generates its Xcode project with XcodeGen
./scripts/build.sh dev   # clone idb, build XCFrameworks
make build               # build sim-use
```

The FB* XCFrameworks are static archives built without library evolution —
`build_products/` is locked to the toolchain that produced it. Re-run
`./scripts/build.sh dev` after switching Xcode versions.

### Daily workflow

```bash
make build                                           # incremental build
.build/debug/sim-use describe-ui --device $UDID      # test against a booted simulator
```

### Running tests

```bash
make test                        # unit tests (no simulator needed)
swift test --filter TapTests     # run a single test suite
```

`make test` runs `swift test --enable-code-coverage` — unit tests that exercise parsing, outline rendering, daemon protocol, and cross-platform dispatch without a live simulator.

When [xcsift](https://github.com/ldomaradzki/xcsift) is installed (`brew install xcsift` — optional, never required), `make build` / `make test` condense swift output into a TOON summary plus a coverage report. `SIM_USE_XCSIFT=0 make test` forces plain swift output.

### End-to-end tests (live device)

```bash
make e2e            # BOTH iOS + Android in sequence (needs a booted sim AND an emulator)
make e2e-ios        # iOS only — booted simulator + Playground fixture
make e2e-android    # Android only — reachable device/emulator + Playground fixture
make e2e-matrix     # iOS across Xcode 26/27 × Device Hub closed/open legs (~35 min default)
make eval           # agent evals (real `claude -p` cost; prompts before running)
```

E2E suites compile always but skip unless `SIM_USE_E2E=1` (iOS) / `SIM_USE_E2E_ANDROID=1` (Android) is set — `make test` never touches a device, which is why CI needs no simulator. The runners set those vars for you.

**Budget the time: a full green `make e2e-ios` run is ~15 minutes.** The iOS suites drive real HID gestures and wait on simulator animations/keyboard settling, so per-suite waits dominate — this is expected, not a hang. `make e2e` (both platforms) is ~20+ min. When you only touched one platform, run just that platform's target. The runners keep going past a failed suite and print a full pass/fail map at the end, so read the summary rather than assuming the first red aborted the rest.

`make e2e-matrix` validates the host-environment matrix: Xcode 26.x / 27.x × Device Hub closed at boot (`*-sim` legs — the Simulator.app workflow, legacy HID) or open at boot (`*-hub` legs — CoreDevice dtuhidd HID). One leg runs the full suite (default `x27-hub`; `ARGS="--full <leg>|all|none"`), the rest run the smoke tier (`scripts/test-runner.sh --smoke`: describe-ui, tap, type, scroll); legs whose Xcode is missing are skipped. The package builds once on the xcode-select toolchain — each leg only swaps the runtime Xcode via `SIM_USE_TEST_DEVELOPER_DIR` and boots a device matching its iOS generation, with dtuhidd/transport gates before and after the suites so a choreography failure cannot green-run the wrong combination. It quits Device Hub and shuts down every booted simulator, so never run it alongside other simulator work. Per-leg logs + evidence: `.build/e2e-matrix/<timestamp>/`.

Agent-facing behaviour (the bundled skill) has its own natural-language eval layer — see `e2e/agent-evals/README.md` and `docs/ai/xxxx-e2e-confidence-suite/`.

### Verifying a change

After any non-trivial change, at minimum:

1. `make build` succeeds.
2. `make test` passes.
3. Spot-check the affected command on a live simulator (`describe-ui`, `tap @N`, `screenshot`).

## Module layout

Five SwiftPM targets; dependency graph flows in one direction.

| Target | Path | Depends on |
|---|---|---|
| `SimUseCore` | `Sources/SimUseCore/` | Foundation + ArgumentParser |
| `SimUseVideo` | `Sources/SimUseVideo/` | SimUseCore + AVFoundation/ImageIO |
| `iOSSimBackend` | `Sources/iOSSimBackend/` | SimUseCore + SimUseVideo + FB* XCFrameworks + AVFoundation |
| `AndroidBackend` | `Sources/AndroidBackend/` | SimUseCore + SimUseVideo + ArgumentParser |
| `SimUse` (executable) | `Sources/SimUse/` | SimUseCore + SimUseVideo + iOSSimBackend + AndroidBackend + FB* |

`SimUseVideo` holds the platform-neutral host-side video plumbing (H.264 Annex B parsing, passthrough muxing, `AVAssetWriter` encoding, frame utilities) shared by the iOS and Android recording/streaming paths. It must stay FB*-free — anything that needs FBSimulatorControl belongs in `iOSSimBackend` (e.g. the `VideoFrameUtilities.captureScreenshotData` extension), anything adb-shaped in `AndroidBackend`.

### Verb dispatch

A verb (tap, swipe, type, ...) reaches three surfaces:

1. **Top-level** — `Sources/SimUse/Commands/<Verb>.swift`. Resolves the target via `PlatformRouter`, then forwards to the iOS or Android backend.
2. **`sim-use ios <verb>`** — `Sources/iOSSimBackend/Verbs/IOSSim<Verb>Command.swift`.
3. **`sim-use android <verb>`** — `Sources/AndroidBackend/Verbs/Android<Verb>Command.swift`.

Four verbs are iOS-only (`key`, `key-combo`, `key-sequence`, `batch`) — no top-level alias.

### Adding a new verb

- **Cross-platform**: write `IOSSim<Verb>Command` + `Android<Verb>Command`, plus a top-level forwarder in `Sources/SimUse/Commands/<Verb>.swift`. Register in `IOSSimCommand.swift`, `AndroidCommand.swift`, and `main.swift`.
- **iOS-only**: write `IOSSim<Verb>Command`, register in `IOSSimCommand` only. Use `HIDKeyCommandHelp.androidUnsupportedMessage` to reject Android UDIDs (see `IOSSimKeyCommand`).
- **Shared flags**: `@OptionGroup var udid: UDIDOptions` + `@OptionGroup var json: JSONOutputOptions`.

### Daemon

`SimUseExecutableCommand.run()` forwards UDID-scoped verbs to a per-UDID auto-spawned daemon (`Sources/SimUseCore/Daemon/`). Platform-agnostic — both iOS and Android verbs route through it. Key regression test: `Tests/DaemonCommandParserInjectionTests.swift`.

## Fork先での実装規約（iOS）

- iOS Simulatorの操作・状態取得・Viewer・アプリ向けAPIは、CLI経由で実装しない。`Process`で`sim-use`自身、`xcrun`、`simctl`などを起動したり、CLIの標準入出力やJSON envelopeを経由したりしてはならない。
- iOSの正規の実装経路は、SwiftからFBSimulatorControl/CoreSimulatorなどの内部実装へ直接ブリッジすること。必要な処理は型付きのSwift interfaceとして実装し、CLIコマンドはその薄い入口に限定する。
- iOSコマンドからdaemonプロセスやdaemon socketへ処理を転送してはならない。状態保持が必要な場合も、Swiftのactor・session・直接ブリッジで解決する。
- 直接ブリッジが利用できない場合にCLIへフォールバックしてはならない。型付きエラーとして呼び出し元へ返し、利用可能なSwift bridgeを追加する。
- 新しい`SimUseKit`の公開APIは、`import SimUseKit`だけで利用できる明示的な`public`型として提供し、CLIのArgumentParser型を公開APIの依存にしない。
- iOSの既存コードを変更するときは、`Process(`、`xcrun`、`simctl`、`Bundle.main.executablePath`、daemon呼び出しを検索し、CLI経由が混入していないことを確認する。
- Android側はこの規約の対象外とし、既存の`adb`/bridge経路をiOS対応のために変更しない。

## Android development

The `bridge/` directory contains a Kotlin Android app (AccessibilityService + HTTP server) that the Swift CLI talks to over `adb forward`.

### Required tooling

| Tool | Version |
|---|---|
| Android SDK | `compileSdk=35`, `minSdk=30` |
| JDK | **17 -- 21** (Gradle 8.7 rejects 22+) |
| Gradle | 8.7 (wrapper in `bridge/gradlew`) |

`scripts/build-bridge.sh` auto-detects JDK and SDK paths. Run `scripts/build-bridge.sh --check` to verify the environment.

### Bridge wire spec

- `BuildConfig.PROTOCOL_VERSION` (Kotlin) and `BridgeClient.expectedProtocolVersion` (Swift) must match — bump together on breaking wire changes only.
- `versionCode` / `versionName` in `bridge/app/build.gradle.kts` — bump on any APK change.
- Endpoints: `bridge/.../server/ActionRouter.kt`; handlers in `.../handler/`.

### Bundling the APK

The APK is gitignored (`Sources/AndroidBackend/Resources/*.apk`). Run `scripts/build-bridge.sh` before `make build` so the binary includes Android support.
