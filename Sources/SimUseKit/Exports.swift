// SPDX-License-Identifier: Apache-2.0

/// Re-export the value types used by SimUseKit's public request and result
/// models. Application targets only need to import SimUseKit; they do not
/// need to know that these shared types are implemented in SimUseCore.
@_exported import SimUseCore
@_exported import iOSSimBackend
@_exported import AndroidBackend

/// Public facade for the gesture preset value used by application-facing
/// requests. Keep this explicit so `import SimUseKit` is sufficient even
/// when a client does not import the implementation target directly.
public typealias GesturePreset = SimUseCore.GesturePreset
