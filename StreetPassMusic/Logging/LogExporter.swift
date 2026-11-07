import Foundation
import SwiftData
import UIKit

/// デバッグログと履歴を JSON Lines で書き出す
enum LogExporter {
    private static var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func deviceInfo() -> [String: String] {
        let device = UIDevice.current
        let bundle = Bundle.main
        return [
            "model": device.model,
            "systemVersion": device.systemVersion,
            "appVersion": bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": bundle.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off",
        ]
    }

    static func exportDebugEvents(_ events: [DebugEvent]) throws -> URL {
        let formatter = isoFormatter
        var lines: [String] = []
        lines.append(jsonLine(["kind": "meta", "exportedAt": formatter.string(from: .now), "device": deviceInfo()]))
        for e in events {
            lines.append(jsonLine([
                "kind": "debug",
                "t": formatter.string(from: e.timestamp),
                "appState": e.appState,
                "type": e.eventType,
                "outcome": e.outcome,
                "details": e.details,
                "peer": e.peer ?? NSNull(),
            ]))
        }
        return try write(lines: lines, name: "streetpass-debug")
    }

    static func exportHistory(_ events: [PassbyEvent]) throws -> URL {
        let formatter = isoFormatter
        var lines: [String] = []
        lines.append(jsonLine(["kind": "meta", "exportedAt": formatter.string(from: .now), "device": deviceInfo()]))
        for e in events {
            lines.append(jsonLine([
                "kind": "passby",
                "t": formatter.string(from: e.receivedAt),
                "title": e.receivedTitle,
                "artist": e.receivedArtist,
                "url": e.receivedURL ?? NSNull(),
                "status": e.statusRaw,
                "role": e.roleRaw,
                "peerToken": e.peerToken,
                "failureReason": e.failureReason ?? NSNull(),
            ]))
        }
        return try write(lines: lines, name: "streetpass-history")
    }

    private static func jsonLine(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func write(lines: [String], name: String) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(stamp.string(from: .now)).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
