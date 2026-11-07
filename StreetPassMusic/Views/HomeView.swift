import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(PassbyManager.self) private var manager
    @Query(sort: \MySong.updatedAt, order: .reverse) private var songs: [MySong]
    @Query(sort: \PassbyEvent.receivedAt, order: .reverse) private var history: [PassbyEvent]

    private var song: MySong? { songs.first }

    private var recentCount: Int {
        let since = Date().addingTimeInterval(-24 * 60 * 60)
        return history.filter { $0.receivedAt >= since }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("登録中の曲") {
                    if let song {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title).font(.headline)
                            Text(song.artist).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("未登録。「曲登録」タブで設定してください。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("すれ違い通信") {
                    Toggle("すれ違い通信", isOn: Binding(
                        get: { manager.isEnabled },
                        set: { manager.setEnabled($0) }
                    ))
                    .disabled(song == nil && !manager.isEnabled)
                    if song == nil {
                        Text("曲を登録するとオンにできます").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Bluetooth の状態") {
                    LabeledContent("Central（検出）", value: manager.centralState.japanese)
                    LabeledContent("Peripheral（発信）", value: manager.peripheralState.japanese)
                    LabeledContent("スキャン", value: manager.isScanning ? "実行中" : "停止")
                    LabeledContent("広告", value: manager.isAdvertising ? "実行中" : "停止")
                    if manager.centralState == .unauthorized {
                        Text("設定アプリで Bluetooth の許可を有効にしてください。")
                            .font(.footnote).foregroundStyle(.red)
                    } else if manager.centralState == .poweredOff {
                        Text("Bluetooth がオフです。コントロールセンターまたは設定で有効にしてください。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("交換状況") {
                    LabeledContent("24時間以内に受信", value: "\(recentCount) 件")
                    LabeledContent("履歴の合計", value: "\(history.count) 件")
                }
            }
            .navigationTitle("StreetPass Music")
        }
    }
}
