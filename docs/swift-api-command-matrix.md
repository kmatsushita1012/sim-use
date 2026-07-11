# Swift API command matrix

この表は、既存の CLI が公開しているコマンドと、現在の daemon 経路で実行できるかを整理したものです。`daemon` は `SimUseExecutableCommand` として `DaemonDispatch` から直接 `execute()` されるコマンド、`bypass` は既存実装が daemon を使わずクライアントプロセス内で実行するコマンドを示します。

| Platform | CLI command | Existing implementation | Daemon | Swift API plan | Result |
| --- | --- | --- | --- | --- | --- |
| iOS | `describe-ui` / `ui` | `IOSSimDescribeUICommand` | yes | typed request | `DescribeUIResult` |
| iOS | `tap` | `IOSSimTapCommand` | yes | typed request | tap coordinates / advisory |
| iOS | `swipe` | `IOSSimSwipeCommand` | yes | typed request | `SwipeCoordinates` |
| iOS | `touch` | `IOSSimTouchCommand` | yes | typed request + session events | empty result |
| iOS | `type` | `IOSSimTypeCommand` | yes* | typed request | typed completion result |
| iOS | `paste` | `IOSSimPasteCommand` | yes* | typed request | typed completion result |
| iOS | `button` | `IOSSimButtonCommand` | yes | typed request | typed completion result |
| iOS | `gesture` | `IOSSimGestureCommand` | yes | typed request | typed completion result |
| iOS | `multi-touch` | `IOSSimMultiTouchCommand` | yes | typed request | empty result |
| iOS | `keyboard-state` | `IOSSimKeyboardStateCommand` | yes | typed request | keyboard state |
| iOS | `key` | `IOSSimKeyCommand` | yes | typed request | typed completion result |
| iOS | `key-combo` | `IOSSimKeyComboCommand` | yes | typed request | typed completion result |
| iOS | `key-sequence` | `IOSSimKeySequenceCommand` | yes | typed request | typed completion result |
| iOS | `batch` | `IOSSimBatchCommand` | yes* | typed plan request | batch result |
| iOS | `screenshot` | `IOSSimScreenshotCommand` | bypass | direct API | file/data result |
| iOS | `record-video` | `IOSSimRecordVideoCommand` | bypass | direct API | file result |
| iOS | `stream-video` | `IOSSimStreamVideoCommand` | bypass | direct API / AsyncSequence | stream summary |
| Android | `describe-ui` / `ui` | `AndroidDescribeUICommand` | yes | typed request | `DescribeUIResult` |
| Android | `tap` | `AndroidTapCommand` | yes | typed request | tap coordinates |
| Android | `swipe` | `AndroidSwipeCommand` | yes | typed request | swipe coordinates |
| Android | `touch` | `AndroidTouchCommand` | yes | typed request | empty result |
| Android | `type` | `AndroidTypeCommand` | yes | typed request | typed completion result |
| Android | `paste` | `AndroidPasteCommand` | yes | typed request | typed completion result |
| Android | `button` | `AndroidButtonCommand` | yes | typed request | typed completion result |
| Android | `gesture` | `AndroidGestureCommand` | yes | typed request | typed completion result |
| Android | `multi-touch` | `AndroidMultiTouchCommand` | yes | typed request | typed completion result |
| Android | `scroll` | `AndroidScrollCommand` | yes | typed request | scroll coordinates |
| Android | `keyboard-state` | `AndroidKeyboardStateCommand` | yes | typed request | keyboard state |
| Android | `init` | `AndroidInitCommand` | bypass | direct API | bridge setup result |
| Android | `ping` | `AndroidPingCommand` | bypass | direct API | bridge status |
| Android | `screenshot` | `AndroidScreenshotCommand` | bypass | direct API | file/data result |

`type --stdin`、`paste --stdin`、および iOS `batch` の stdin/file 入力は、既存 CLI では daemon bypass です。Swift API では stdin/file を使わず、`String` または typed plan を直接受け取ります。

`SimUseKit` の `SimUseClient.execute(_:on:)` は、既存の全
`SimUseExecutableCommand` に対する generic typed interface でもあります。
専用 request がないコマンドは、`SimUseKit` が提供する typed alias の public
properties を設定してから渡せます。これは CLI の再パースではなく、対象
command の `resolveDeferredArguments()`、`validate()`、`execute()` を直接呼びます。

`devices`、`list-simulators`、`app-state`、daemon 管理 (`daemon status` / `stop` など) は、対象 Simulator に紐づく daemon command ではありません。Swift API では別の device/session 管理 API として扱います。

## エラー分類

Swift API は daemon の JSON envelope を再利用せず、`SimUseError` として次の分類を公開します。

- `invalidRequest`: 引数・組み合わせが不正
- `deviceNotFound`: 対象 device が見つからない
- `deviceNotBooted`: device が起動していない
- `staleSession`: Simulator 再起動などで接続が無効化された
- `transient`: 一時的な接続・起動状態の失敗
- `backend`: iOS/Android backend の実装エラー

既存の `LocalizedError`、`HintProviding`、daemon の error kind は、API 境界で失われないよう underlying error と hint を保持します。
