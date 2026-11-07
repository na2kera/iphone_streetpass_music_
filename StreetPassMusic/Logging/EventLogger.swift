import Foundation
import SwiftData
import UIKit
import os

/// 実験ログを SwiftData に記録する。BLE のコールバックは main queue で受けるため MainActor 前提。
@MainActor
@Observable
final class EventLogger {
    enum EventType: String {
        case lifecycle, scan, advertise, discovered, connect, disconnect, read, write, save, cooldown, restore, error
    }

    enum Outcome: String {
        case ok, skipped, failed, started, stopped, info
    }

    struct Counter {
        var count = 0
        var lastAt: Date?
    }

    private(set) var counters: [EventType: Counter] = [:]
    private(set) var lastError: String?

    private let context: ModelContext
    private let oslog = Logger(subsystem: "com.keranatsuki.streetpassmusic", category: "ble")

    init(context: ModelContext) {
        self.context = context
    }

    func log(_ type: EventType, _ outcome: Outcome, _ details: String, peer: String? = nil) {
        let state = Self.currentAppState()
        let event = DebugEvent(appState: state, eventType: type.rawValue, outcome: outcome.rawValue, details: details, peer: peer)
        context.insert(event)
        try? context.save()

        var counter = counters[type] ?? Counter()
        counter.count += 1
        counter.lastAt = event.timestamp
        counters[type] = counter
        if type == .error || outcome == .failed {
            lastError = "\(type.rawValue): \(details)"
        }
        oslog.info("[\(state, privacy: .public)] \(type.rawValue, privacy: .public)/\(outcome.rawValue, privacy: .public) \(details, privacy: .public) peer=\(peer ?? "-", privacy: .public)")
    }

    func clearAll() {
        try? context.delete(model: DebugEvent.self)
        try? context.save()
        counters = [:]
        lastError = nil
    }

    /// active / inactive / background に、ロック中なら "+locked" を付ける
    static func currentAppState() -> String {
        let app = UIApplication.shared
        let base: String
        switch app.applicationState {
        case .active: base = "active"
        case .inactive: base = "inactive"
        case .background: base = "background"
        @unknown default: base = "unknown"
        }
        return app.isProtectedDataAvailable ? base : base + "+locked"
    }
}
