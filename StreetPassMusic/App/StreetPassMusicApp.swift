import SwiftData
import SwiftUI

@main
struct StreetPassMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// 生成に失敗した場合は nil。その場合はエラー画面を表示し、BLE は開始しない。
    private let container: ModelContainer?
    private let manager: PassbyManager?
    private let containerError: String?

    init() {
        let schema = Schema([MySong.self, PassbyEvent.self, DebugEvent.self])
        let config = ModelConfiguration(schema: schema)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext
            let logger = EventLogger(context: context)
            // 古いログを先に整理してから BLE を開始する
            logger.pruneIfNeeded()
            self.container = container
            // State Restoration のため、通信オン中は起動直後に Manager を生成する
            // （復元による起動かどうかは willRestoreState のログで判別する）
            self.manager = PassbyManager(context: context, logger: logger)
            self.containerError = nil
        } catch {
            self.container = nil
            self.manager = nil
            self.containerError = String(describing: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container, let manager {
                RootView()
                    .environment(manager)
                    .modelContainer(container)
            } else {
                ContentUnavailableView(
                    "データベースを開けませんでした",
                    systemImage: "exclamationmark.triangle",
                    description: Text(containerError ?? "不明なエラー")
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: manager?.appDidBecomeActive()
            case .background: manager?.appDidEnterBackground()
            default: break
            }
        }
    }
}
