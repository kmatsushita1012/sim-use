// SPDX-License-Identifier: Apache-2.0
import AndroidBackend
import iOSSimBackend

/// Typed compatibility aliases for commands that do not yet have a
/// dedicated application-facing request. They are intentionally aliases,
/// not new CLI wrappers: `SimUseClient.execute(_:on:)` invokes their existing
/// `execute()` implementation directly and never invokes ArgumentParser.
/// Construct an alias with `parse`, including its `--device` argument, before
/// passing it to the client. Prefer a dedicated `SimUseRequest` when one
/// exists; the aliases cover the complete current command surface and future
/// commands that conform to `SimUseExecutableCommand`.
public typealias IOSDescribeUICommand = IOSSimDescribeUICommand
public typealias IOSTapCommand = IOSSimTapCommand
public typealias IOSSwipeCommand = IOSSimSwipeCommand
public typealias IOSTouchCommand = IOSSimTouchCommand
public typealias IOSTypeCommand = IOSSimTypeCommand
public typealias IOSPasteCommand = IOSSimPasteCommand
public typealias IOSButtonCommand = IOSSimButtonCommand
public typealias IOSGestureCommand = IOSSimGestureCommand
public typealias IOSMultiTouchCommand = IOSSimMultiTouchCommand
public typealias IOSKeyboardStateCommand = IOSSimKeyboardStateCommand
public typealias IOSKeyCommand = IOSSimKeyCommand
public typealias IOSKeyComboCommand = IOSSimKeyComboCommand
public typealias IOSKeySequenceCommand = IOSSimKeySequenceCommand
public typealias IOSBatchCommand = IOSSimBatchCommand
public typealias IOSScreenshotCommand = IOSSimScreenshotCommand
public typealias IOSRecordVideoCommand = IOSSimRecordVideoCommand
public typealias IOSStreamVideoCommand = IOSSimStreamVideoCommand

public typealias AndroidDescribeUICommand = AndroidBackend.AndroidDescribeUICommand
public typealias AndroidTapCommand = AndroidBackend.AndroidTapCommand
public typealias AndroidSwipeCommand = AndroidBackend.AndroidSwipeCommand
public typealias AndroidTouchCommand = AndroidBackend.AndroidTouchCommand
public typealias AndroidTypeCommand = AndroidBackend.AndroidTypeCommand
public typealias AndroidPasteCommand = AndroidBackend.AndroidPasteCommand
public typealias AndroidButtonCommand = AndroidBackend.AndroidButtonCommand
public typealias AndroidGestureCommand = AndroidBackend.AndroidGestureCommand
public typealias AndroidMultiTouchCommand = AndroidBackend.AndroidMultiTouchCommand
public typealias AndroidScrollCommand = AndroidBackend.AndroidScrollCommand
public typealias AndroidKeyboardStateCommand = AndroidBackend.AndroidKeyboardStateCommand
public typealias AndroidDevicesCommand = AndroidBackend.AndroidDevicesCommand
public typealias AndroidInitCommand = AndroidBackend.AndroidInitCommand
public typealias AndroidPingCommand = AndroidBackend.AndroidPingCommand
public typealias AndroidScreenshotCommand = AndroidBackend.AndroidScreenshotCommand
