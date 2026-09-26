// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

enum IOSDeviceCommandError: Error, LocalizedError, CustomStringConvertible, HintProviding {
    case noMatchingElement(selector: String, available: [String])
    case multipleMatches(selector: String, matches: [String])
    case missingSelector

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .noMatchingElement(selector, available):
            let candidates = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "no accessibility element matched \(selector) on screen (available: \(candidates))"
        case let .multipleMatches(selector, matches):
            return "\(selector) matched multiple accessibility elements (\(matches.joined(separator: ", ")))"
        case .missingSelector:
            return "tap requires exactly one of `#id` / --id, --label, or --label-contains"
        }
    }

    // The recovery advice rides the `hint` channel so the `--json` error
    // envelope carries it structurally; the text path prints it as a
    // `Hint:` line after the error.
    var hint: String? {
        switch self {
        case .noMatchingElement:
            return "Run 'sim-use ios-device ui' and choose a visible label or #id from the current screen."
        case .multipleMatches:
            return "Use --label for an exact match, or add --element-type to disambiguate."
        case .missingSelector:
            return nil
        }
    }
}

struct DeviceTapTargetResolver {
    static func resolve(
        _ elements: [DeviceElement],
        identifier: String? = nil,
        label: String? = nil,
        labelContains: String? = nil,
        elementType: String? = nil
    ) throws -> DeviceElement {
        // Elements sim-use can act on, narrowed by --element-type first (as the
        // simulator resolver does), so the selector match runs on the same pool.
        let accessible = elements.filter(\.isAccessibilityElement)
        let pool = elementType.map { type in
            accessible.filter { $0.role.localizedCaseInsensitiveCompare(type) == .orderedSame }
        } ?? accessible

        let selectorDescription: String
        let matches: [DeviceElement]
        // The button-preference tie-break only makes sense for label selectors,
        // where a button and a nested static-text node legitimately share a
        // label. An accessibility identifier is a literal, unique handle (as on
        // the simulator / Android surfaces), so a duplicate id is a genuine
        // ambiguity to report, not something to silently resolve to the button.
        let preferButtonOnAmbiguity: Bool

        if let identifier {
            // Exact, case-sensitive comparison — an identifier is literal
            // identity, not human text — trimming both sides, matching the
            // simulator's `--id` (`normalizedUniqueId == trimmed query`).
            let target = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            selectorDescription = "#\(identifier)"
            matches = pool.filter { $0.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) == target }
            preferButtonOnAmbiguity = false
        } else if let label {
            // Use the shared text-matching policy (case-sensitive, exact-first
            // with a whitespace-collapsed fallback) that the simulator and
            // Android resolvers use, so label matching does not drift per
            // platform.
            selectorDescription = "--label '\(label)'"
            matches = SelectorTextMatcher.filterEquals(pool, query: label) {
                DeviceOutline.label(from: $0.summary, role: $0.role)
            }
            preferButtonOnAmbiguity = true
        } else if let labelContains {
            selectorDescription = "--label-contains '\(labelContains)'"
            matches = SelectorTextMatcher.filterContains(pool, needle: labelContains) {
                DeviceOutline.label(from: $0.summary, role: $0.role)
            }
            preferButtonOnAmbiguity = true
        } else {
            throw IOSDeviceCommandError.missingSelector
        }

        guard !matches.isEmpty else {
            throw IOSDeviceCommandError.noMatchingElement(
                selector: selectorDescription,
                available: Array(accessible.prefix(8).map(describe))
            )
        }
        if matches.count == 1 { return matches[0] }

        // Hierarchies commonly contain a button and a nested static-text node
        // with the same label. Match the actionable button just as the regular
        // simulator resolver prefers actionable elements.
        if preferButtonOnAmbiguity {
            let buttons = matches.filter { $0.role.localizedCaseInsensitiveContains("button") }
            if buttons.count == 1 { return buttons[0] }
        }

        throw IOSDeviceCommandError.multipleMatches(
            selector: selectorDescription,
            matches: Array(matches.prefix(8).map(describe))
        )
    }

    static func describe(_ element: DeviceElement) -> String {
        describe(
            role: element.role,
            label: DeviceOutline.label(from: element.summary, role: element.role),
            identifier: element.identifier
        )
    }

    /// Field-based variant so `format(_:)` can reproduce the same string
    /// from a decoded `ExecutionResult` without a live element.
    static func describe(role: String, label: String, identifier: String?) -> String {
        let id = identifier.map { " #\($0)" } ?? ""
        return "'\(label)' [\(role)]\(id)"
    }
}

public struct IOSDeviceCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ios-device",
        abstract: "Physical iOS device subcommands (experimental).",
        discussion: """
        Experimental support for driving a connected iPhone or iPad through
        the accessibility audit daemon. sim-use installs and signs no runner,
        and needs no Developer Disk Image. The device must be paired, trusted,
        unlocked and in Developer Mode; the foreground app must be
        development-signed (get-task-allow=true).
        Distribution-signed and system apps are unsupported. A Release build
        remains supported when installed with a Development profile.

        Element geometry is not available on this channel, so there is no
        coordinate tap, swipe or gesture here; interaction goes through
        accessibility actions instead. The display itself can still be
        captured with `screenshot`.
        """,
        subcommands: [Devices.self, UI.self, Screenshot.self, Tap.self]
    )

    public init() {}

    struct DeviceOptions: ParsableArguments {
        @Option(
            name: [.customLong("device"), .customLong("udid")],
            help: "UDID or ECID of the device. Optional when exactly one is connected."
        )
        var udid: String?
    }

    struct Devices: SimUseExecutableCommand {
        static let configuration = CommandConfiguration(
            commandName: "devices",
            abstract: "List connected physical iOS devices."
        )

        @OptionGroup var json: JSONOutputOptions

        var jsonOutput: Bool { json.enabled }

        /// Rows reuse the unified `Device` schema (`deviceId` / `kind` /
        /// `runtime` keys) that top-level `sim-use devices --json` emits,
        /// so consumers parse one shape regardless of which listing they
        /// called.
        struct ExecutionResult: Codable {
            let devices: [Device]
        }

        func execute() async throws -> ExecutionResult {
            ExecutionResult(devices: try await DeviceSession.connectedDevices().map(\.unifiedDevice))
        }

        func format(_ result: ExecutionResult) -> CommandOutput {
            guard !result.devices.isEmpty else {
                return .line("No physical iOS devices connected.")
            }
            return .lines(result.devices.map { device in
                [device.udid, device.name, device.runtime ?? "-", device.state].joined(separator: "  ")
            })
        }
    }

    public struct UI: SimUseExecutableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "ui",
            abstract: "Print an outline of the foreground app's accessibility tree."
        )

        @OptionGroup var device: DeviceOptions

        @Option(help: "Number of hierarchy reads to keep in flight.")
        var concurrency: Int = DeviceTreeFetcher.defaultConcurrency

        @Option(help: "Number of DTX connections to spread reads over.")
        var connections: Int = 1

        @Flag(help: "Stop descending at labelled elements. Faster, but misses nested text.")
        var fast = false

        @OptionGroup var json: JSONOutputOptions

        public var jsonOutput: Bool { json.enabled }

        public init() {}

        /// `rows` is the structured outline; `outline` is the same rows
        /// rendered as the text the default mode prints, mirroring the
        /// simulator envelope where agents read `data.outline` directly.
        /// There are deliberately no `@N` aliases in either form —
        /// element handles expire with the DTX connection.
        public struct ExecutionResult: Codable {
            public let outline: String
            public let rows: [DeviceOutline.Row]
            public let elements: Int
            public let nodes: Int
            public let elapsedMs: Int
        }

        public func validate() throws {
            guard concurrency > 0 else { throw ValidationError("--concurrency must be greater than zero") }
            guard connections > 0 else { throw ValidationError("--connections must be greater than zero") }
        }

        public func execute() async throws -> ExecutionResult {
            try await Self.performUI(udid: device.udid, concurrency: concurrency, connections: connections, fast: fast)
        }

        /// Typed executor entry point shared with the top-level
        /// `describe-ui` forwarder (mirroring
        /// `IOSSimTapCommand.performTap`) — parsed values are handed
        /// over directly, so no backend command instance is hand-built
        /// and there is no per-field copy to forget (#42).
        public static func performUI(
            udid: String?,
            concurrency: Int = DeviceTreeFetcher.defaultConcurrency,
            connections: Int = 1,
            fast: Bool = false
        ) async throws -> ExecutionResult {
            let started = Date()
            let (outline, total) = try await DeviceSession.withClient(udid: udid, connections: connections) { client in
                let elements = try await DeviceTreeFetcher(client: client, concurrency: concurrency, stopsAtLabelledNodes: fast).fetchTree()
                return (DeviceOutline(elements: elements), elements.count)
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return ExecutionResult(
                outline: outline.rendered(),
                rows: outline.rows,
                elements: outline.rows.count,
                nodes: total,
                elapsedMs: elapsed
            )
        }

        public func format(_ result: ExecutionResult) -> CommandOutput {
            .raw(Self.renderedText(result))
        }

        /// The full text block default mode prints (outline + summary
        /// line). Shared with the top-level `describe-ui` forwarder so
        /// the routed surface stays byte-identical to this namespace.
        public static func renderedText(_ result: ExecutionResult) -> String {
            "\(result.outline)\n\n\(result.elements) elements (\(result.nodes) nodes) in \(result.elapsedMs) ms\n"
        }
    }

    public struct Screenshot: SimUseExecutableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "screenshot",
            abstract: "Capture a screenshot of the device display and save it as a PNG file.",
            discussion: """
            Captures over CoreDevice (`xcrun devicectl device capture
            screenshot`) rather than the accessibility audit channel, so it
            is not limited to development-signed foreground apps: whatever is
            on screen is captured, SpringBoard and system apps included. The
            device is selected exactly like the other ios-device verbs.
            """
        )

        @OptionGroup var device: DeviceOptions

        @Option(help: "Output PNG file path. Defaults to 'Device Screenshot - <device name> - <timestamp>.png' in the current directory.")
        var output: String?

        @OptionGroup var json: JSONOutputOptions

        public var jsonOutput: Bool { json.enabled }

        public init() {}

        public struct ExecutionResult: Codable {
            public let path: String
        }

        /// Mirrors the simulator's default naming so paired screenshots from
        /// cross-platform sessions sort together. The device name is
        /// user-editable free text, so it is collapsed into a single safe
        /// path component first — "My iPhone/Work" must not create a
        /// directory hierarchy. Static so tests can pin the convention
        /// without a device.
        static func defaultFilename(deviceName: String, at date: Date) -> String {
            "Device Screenshot - \(OutputFilePath.safeFilenameComponent(deviceName)) - \(OutputFilePath.screenshotTimestamp(date)).png"
        }

        /// Resolve, validate the extension, then ensure the parent directory
        /// exists — nothing here removes an existing file, so neither a
        /// rejected path nor a later capture failure can destroy one.
        /// Static so tests can pin that guarantee without a device.
        static func resolveOutputURL(output: String?, deviceName: String) throws -> URL {
            let url = OutputFilePath.resolve(output: output) {
                defaultFilename(deviceName: deviceName, at: Date())
            }
            guard url.pathExtension.lowercased() == "png" else {
                throw CLIError(errorDescription: "devicectl writes PNG only — use an output path ending in .png (got '\(url.lastPathComponent)')")
            }
            try OutputFilePath.createParentDirectory(for: url)
            return url
        }

        /// Captures into a temporary sibling file and moves it over the final
        /// target only on success, so a capture that fails mid-flight (device
        /// unplugged, devicectl timeout) leaves an existing file at --output
        /// untouched. The temporary basename is fixed and short — deriving it
        /// from the target name would push a NAME_MAX-length (255-byte)
        /// target over the per-component limit — and keeps the .png suffix
        /// devicectl requires. Injectable capture so tests can pin the
        /// failure branch.
        static func captureAtomically(to url: URL, capture: (URL) throws -> Void) throws {
            let fileManager = FileManager.default
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".sim-use-screenshot-partial-\(UUID().uuidString).png")
            do {
                try capture(temporary)
                if fileManager.fileExists(atPath: url.path) {
                    _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: url)
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }

        public func execute() async throws -> ExecutionResult {
            try await Self.performScreenshot(udid: device.udid, output: output)
        }

        /// Typed executor entry point shared with the top-level
        /// `screenshot` forwarder — parsed values are handed over
        /// directly, so no backend command instance is hand-built (#42).
        public static func performScreenshot(udid: String?, output: String?) async throws -> ExecutionResult {
            let summary = try await DeviceSession.resolveDevice(udid: udid)
            let url = try resolveOutputURL(output: output, deviceName: summary.name)
            try captureAtomically(to: url) { temporary in
                try Devicectl.run(arguments: Devicectl.screenshotArguments(deviceIdentifier: summary.udid, destination: temporary))
            }
            return ExecutionResult(path: url.path)
        }

        public func format(_ result: ExecutionResult) -> CommandOutput {
            CommandOutput(
                stdout: result.path + "\n",
                stderr: "Screenshot saved to \(result.path)\n"
            )
        }
    }

    public struct Tap: SimUseExecutableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "tap",
            abstract: "Activate an element by accessibility identifier or label.",
            discussion: """
            Targeting forms, mirroring the simulator tap where the channel
            allows (there is no `@N` alias — physical-device element handles
            expire between processes — and no coordinate fallback, because the
            daemon exposes no geometry):
              * Positional `#<id>` or `--id <id>` — the accessibility
                identifier shown in `ios-device ui`. Stable across reads, so
                prefer it when a label is dynamic (a back button is labelled
                with the previous screen's title but keeps `#BackButton`).
              * `--label` / `--label-contains` — exact or substring label.
              * `--element-type` disambiguates when several elements match.
            The element is resolved and activated inside one connection because
            the handle cannot be reused later. Fire-and-forget; run
            'ios-device ui' again to verify.
            """
        )

        @OptionGroup var device: DeviceOptions

        @Argument(help: "Positional accessibility identifier, written `#<id>` as shown in ios-device ui.")
        var alias: String?

        @Option(help: "Accessibility identifier from ios-device ui (the `#id`).")
        var id: String?

        @Option(help: "Exact rendered label from ios-device ui.")
        var label: String?

        @Option(help: "Case-sensitive substring of an element label.")
        var labelContains: String?

        @Option(help: "Accessibility role used to disambiguate matches, for example Button.")
        var elementType: String?

        @OptionGroup var json: JSONOutputOptions

        public var jsonOutput: Bool { json.enabled }

        public init() {}

        /// The matched element, in the vocabulary the outline renders
        /// (role / label / trimmed-as-shown identifier). `action` names
        /// the accessibility action sent — Activate is the only one
        /// exposed today, but the key keeps the shape honest when more
        /// (e.g. scroll, #104) arrive.
        public struct ExecutionResult: Codable {
            public let action: String
            public let role: String
            public let label: String
            public let identifier: String?
        }

        /// Identifier from the positional `#id` alias or the `--id` option.
        private var resolvedIdentifier: String? {
            if let id { return id }
            guard let alias else { return nil }
            return alias.hasPrefix("#") ? String(alias.dropFirst()) : alias
        }

        public func validate() throws {
            if alias != nil, id != nil {
                throw ValidationError("specify the identifier once — either the positional `#id` or --id, not both")
            }
            if let alias, !alias.hasPrefix("#") {
                throw ValidationError("positional target must be an identifier written `#\(alias)`; there is no `@N` alias on physical devices — use `#<id>`, --label, or --label-contains")
            }
            let selectors = [resolvedIdentifier, label, labelContains].compactMap { $0 }
            guard selectors.count == 1 else {
                throw ValidationError("specify exactly one of `#id` / --id, --label, or --label-contains")
            }
            guard selectors[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ValidationError("the selector cannot be empty")
            }
            if let elementType, elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--element-type cannot be empty")
            }
        }

        public func execute() async throws -> ExecutionResult {
            try await Self.performTap(
                udid: device.udid,
                identifier: resolvedIdentifier,
                label: label,
                labelContains: labelContains,
                elementType: elementType
            )
        }

        /// Typed executor entry point shared with the top-level `tap`
        /// forwarder — parsed values are handed over directly, so no
        /// backend command instance is hand-built (#42). Expects exactly
        /// one of `identifier` / `label` / `labelContains` (the resolver
        /// rejects other combinations).
        public static func performTap(
            udid: String?,
            identifier: String?,
            label: String?,
            labelContains: String?,
            elementType: String?
        ) async throws -> ExecutionResult {
            try await DeviceSession.withClient(udid: udid) { client in
                let elements = try await DeviceTreeFetcher(client: client).fetchTree()
                let target = try DeviceTapTargetResolver.resolve(
                    elements,
                    identifier: identifier,
                    label: label,
                    labelContains: labelContains,
                    elementType: elementType
                )
                try await client.perform(.activate, on: target.element)
                // Trimmed like the outline renders it, so the reported
                // `identifier` is exactly what `tap '#<id>'` accepts.
                let matchedId = target.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ExecutionResult(
                    action: "Activate",
                    role: target.role,
                    label: DeviceOutline.label(from: target.summary, role: target.role),
                    identifier: matchedId?.isEmpty == false ? matchedId : nil
                )
            }
        }

        public func format(_ result: ExecutionResult) -> CommandOutput {
            .line(Self.summaryLine(result))
        }

        /// The success line default mode prints. Shared with the
        /// top-level `tap` forwarder so the routed surface stays
        /// byte-identical to this namespace.
        public static func summaryLine(_ result: ExecutionResult) -> String {
            "Sent \(result.action) to \(DeviceTapTargetResolver.describe(role: result.role, label: result.label, identifier: result.identifier))"
        }
    }
}
