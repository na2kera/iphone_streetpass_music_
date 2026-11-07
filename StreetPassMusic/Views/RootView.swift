import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("ホーム", systemImage: "house") {
                HomeView()
            }
            Tab("曲登録", systemImage: "music.note") {
                SongEditView()
            }
            Tab("履歴", systemImage: "clock.arrow.circlepath") {
                HistoryView()
            }
            Tab("デバッグ", systemImage: "ladybug") {
                DebugView()
            }
        }
    }
}
