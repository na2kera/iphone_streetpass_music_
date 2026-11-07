import SwiftData
import SwiftUI

struct DebugView: View {
    @Environment(PassbyManager.self) private var manager
    @Query(sort: \DebugEvent.timestamp, order: .reverse) private var events: [DebugEvent]
    @Query(sort: \PassbyEvent.receivedAt, order: .reverse) private var history: [PassbyEvent]

    @State private var debugExportURL: URL?
    @State private var historyExportURL: URL?
    @State private var exportError: String?
    @State private var showClearConfirm = false

    private let counterTypes: [EventLogger.EventType] = [.discovered, .connect, .read, .write, .save, .cooldown, .restore, .error]

    var body: some View {
        NavigationStack {
            List {
                Section("状態") {
                    LabeledContent("Central", value: manager.centralState.label)
                    LabeledContent("Peripheral", value: manager.peripheralState.label)
                    LabeledContent("スキャン中", value: manager.isScanning ? "yes" : "no")
                    LabeledContent("広告中", value: manager.isAdvertising ? "yes" : "no")
                    LabeledContent("進行中の接続", value: "\(manager.activeSessionCount)")
                    LabeledContent("セッショントークン", value: manager.sessionToken)
                    LabeledContent("起動時復元", value: restoreLabel)
                    LabeledContent("アプリ状態", value: EventLogger.currentAppState())
                }

                Section("実験設定") {
                    Toggle("発見のみ（接続・交換しない）", isOn: Binding(
                        get: { manager.discoveryOnly },
                        set: { manager.setDiscoveryOnly($0) }
                    ))
                    Stepper("クールダウン: \(manager.cooldownMinutes) 分", value: Binding(
                        get: { manager.cooldownMinutes },
                        set: { manager.setCooldownMinutes($0) }
                    ), in: 0...30)
                    Button("スキャン・広告を再起動") { manager.restartAll() }
                        .disabled(!manager.isEnabled)
                }

                Section("カウンタ") {
                    ForEach(counterTypes, id: \.rawValue) { type in
                        let counter = manager.logger.counters[type]
                        LabeledContent(type.rawValue) {
                            VStack(alignment: .trailing) {
                                Text("\(counter?.count ?? 0)")
                                if let at = counter?.lastAt {
                                    Text(at.formatted(date: .omitted, time: .standard)).font(.caption2)
                                }
                            }
                        }
                    }
                    if let lastError = manager.logger.lastError {
                        LabeledContent("直近のエラー") {
                            Text(lastError).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("エクスポート") {
                    Button("デバッグログを書き出す（\(events.count) 件）") {
                        debugExportURL = export { try LogExporter.exportDebugEvents(events.reversed()) }
                    }
                    if let url = debugExportURL {
                        ShareLink(item: url) { Label("デバッグログを共有", systemImage: "square.and.arrow.up") }
                    }
                    Button("履歴を書き出す（\(history.count) 件）") {
                        historyExportURL = export { try LogExporter.exportHistory(history.reversed()) }
                    }
                    if let url = historyExportURL {
                        ShareLink(item: url) { Label("履歴を共有", systemImage: "square.and.arrow.up") }
                    }
                    if let exportError {
                        Text(exportError).font(.footnote).foregroundStyle(.red)
                    }
                    Button("デバッグログを全削除", role: .destructive) { showClearConfirm = true }
                }

                Section("端末情報") {
                    ForEach(LogExporter.deviceInfo().sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key, value: value)
                    }
                }

                Section("ログ（新しい順・最大 300 件）") {
                    ForEach(events.prefix(300)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.timestamp.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                                Text(event.eventType).bold()
                                Text(event.outcome).foregroundStyle(event.outcome == "failed" ? .red : .secondary)
                                if let peer = event.peer { Text(peer).foregroundStyle(.tertiary) }
                            }
                            .font(.caption.monospaced())
                            Text(event.details).font(.caption)
                            Text(event.appState).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("デバッグ")
            .confirmationDialog("デバッグログをすべて削除しますか？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("削除", role: .destructive) { manager.logger.clearAll() }
            }
        }
    }

    private var restoreLabel: String {
        switch (manager.restoredCentralAtLaunch, manager.restoredPeripheralAtLaunch) {
        case (true, true): return "central+peripheral"
        case (true, false): return "central"
        case (false, true): return "peripheral"
        default: return "なし"
        }
    }

    private func export(_ make: () throws -> URL) -> URL? {
        do {
            let url = try make()
            exportError = nil
            return url
        } catch {
            exportError = "書き出し失敗: \(error.localizedDescription)"
            return nil
        }
    }
}
