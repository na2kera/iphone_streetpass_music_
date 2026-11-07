import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PassbyEvent.receivedAt, order: .reverse) private var events: [PassbyEvent]
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    ContentUnavailableView("まだすれ違いがありません", systemImage: "person.2.slash",
                                           description: Text("通信をオンにして、同じアプリを使う人と近づいてください。"))
                } else {
                    List {
                        ForEach(events) { event in
                            HistoryRow(event: event)
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(events[i]) }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("すれ違い履歴")
            .toolbar {
                if !events.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("全削除", role: .destructive) { showClearConfirm = true }
                    }
                }
            }
            .confirmationDialog("履歴をすべて削除しますか？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    try? context.delete(model: PassbyEvent.self)
                    try? context.save()
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let event: PassbyEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.receivedTitle).font(.headline)
            Text(event.receivedArtist).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(event.receivedAt.formatted(date: .abbreviated, time: .standard))
                Text(statusLabel)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(event.status == .exchanged ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .clipShape(Capsule())
                Text(event.role == .central ? "検出側" : "発信側")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let urlString = SongURLValidator.sanitized(event.receivedURL), let url = URL(string: urlString) {
                Link("曲を開く", destination: url).font(.caption)
            }
            if let reason = event.failureReason {
                Text(reason).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusLabel: String {
        switch event.status {
        case .exchanged: return "相互交換"
        case .received: return "受信のみ"
        }
    }
}
