// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseKit

// HTTP handlers that mirror the Viewer SPA API. All iOS operations call the
// in-process Swift interface directly; the Viewer never starts `sim-use`,
// reparses ArgumentParser input, or decodes a CLI JSON envelope.
struct ViewerAPIHandlers {
    private let listSimulators: @Sendable () async throws -> [Device]
    private let describeUI: @Sendable (SimulatorID) async throws -> UIResult
    private let tap: @Sendable (SimulatorID, Int) async throws -> TapResult

    init(client: SimUseClient = SimUseClient()) {
        self.listSimulators = { try await client.listSimulators() }
        self.describeUI = { deviceID in
            try await client.execute(DescribeUIRequest(), on: deviceID)
        }
        self.tap = { deviceID, at in
            try await client.execute(TapRequest(alias: "@\(at)"), on: deviceID)
        }
    }

    init(
        listSimulators: @escaping @Sendable () async throws -> [Device],
        describeUI: @escaping @Sendable (SimulatorID) async throws -> UIResult,
        tap: @escaping @Sendable (SimulatorID, Int) async throws -> TapResult
    ) {
        self.listSimulators = listSimulators
        self.describeUI = describeUI
        self.tap = tap
    }

    func devices(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let devices = (try await listSimulators()).map { device in
                [
                    "deviceId": device.udid,
                    "name": device.name,
                    "platform": device.platform.rawValue,
                    "runtime": device.runtime ?? "",
                ] as [String: Any]
            }
            return .json(200, ["ok": true, "devices": devices])
        } catch {
            return failure(error)
        }
    }

    func snapshot(_ request: HTTPRequest) async -> HTTPResponse {
        let deviceId = (request.query["deviceId"]
            ?? request.query["udid"]
            ?? "").trimmingCharacters(in: .whitespaces)
        guard !deviceId.isEmpty else {
            return .json(400, ["ok": false, "error": "deviceId (or udid) query param is required"])
        }

        do {
            let result = try await describeUI(SimulatorID(deviceId))
            return .json(200, [
                "ok": true,
                "capturedAt": iso8601Now(),
                "deviceId": deviceId,
                "platform": result.platform,
                "outline": result.outline,
                "entries": encodableObject(result.entries),
                "lists": encodableObject(result.lists),
                "screen": [
                    "appLabel": result.appLabel,
                    "width": result.screen.width,
                    "height": result.screen.height,
                ],
            ])
        } catch {
            return failure(error)
        }
    }

    func tap(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .json(400, ["ok": false, "error": "body must be JSON object"])
        }
        let deviceId = ((body["deviceId"] as? String)
            ?? (body["udid"] as? String)
            ?? "").trimmingCharacters(in: .whitespaces)
        guard !deviceId.isEmpty else {
            return .json(400, ["ok": false, "error": "deviceId (or udid) is required"])
        }
        guard let at = body["at"] as? Int, at > 0 else {
            return .json(400, ["ok": false, "error": "at must be a positive integer alias"])
        }

        do {
            _ = try await tap(SimulatorID(deviceId), at)
            return .json(200, ["ok": true, "at": at])
        } catch {
            return failure(error)
        }
    }

    private func failure(_ error: Error) -> HTTPResponse {
        .json(502, ["ok": false, "error": error.localizedDescription])
    }

    private func encodableObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        return object
    }

    private func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
