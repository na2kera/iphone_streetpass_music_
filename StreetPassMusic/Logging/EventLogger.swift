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

    /// ログの保持期間（日）と件数上限
    static let retentionDays = 7
    static let maxEvents = 5000

    /// 起動時に呼ぶ。7 日より古いログを削除し、さらに 5000 件を超える分を古い順に削除する。
    func pruneIfNeeded() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(Self.retentionDays) * 24 * 60 * 60)
        var removedByAge = 0
        var removedByCount = 0
        do {
            let oldDescriptor = FetchDescriptor<DebugEvent>(predicate: #Predicate { $0.timestamp < cutoff })
            removedByAge = try context.fetchCount(oldDescriptor)
            if removedByAge > 0 {
                try context.delete(model: DebugEvent.self, where: #Predicate { $0.timestamp < cutoff })
                // 削除を確定させてから数える（未保存のままだと件数に含まれ、上限超過分を消しすぎる）
                try context.save()
            }
            let total = try context.fetchCount(FetchDescriptor<DebugEvent>())
            if total > Self.maxEvents {
                var overflow = FetchDescriptor<DebugEvent>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
                overflow.fetchLimit = total - Self.maxEvents
                for event in try context.fetch(overflow) {
                    context.delete(event)
                }
                removedByCount = total - Self.maxEvents
            }
            try context.save()
        } catch {
            log(.error, .failed, "ログ整理失敗: \(error.localizedDescription)")
            return
        }
        if removedByAge > 0 || removedByCount > 0 {
            log(.lifecycle, .info, "ログ整理 期限切れ\(removedByAge)件 上限超過\(removedByCount)件を削除")
        }
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
