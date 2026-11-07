import SwiftData
import SwiftUI

/// App init で生成し、AppDelegate からも参照できるようにする
@MainActor
enum AppServices {
    static var manager: PassbyManager?
}

@main
struct StreetPassMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    private let manager: PassbyManager

    init() {
        let schema = Schema([MySong.self, PassbyEvent.self, DebugEvent.self])
        let config = ModelConfiguration(schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer の生成に失敗: \(error)")
        }
        let context = container.mainContext
        let logger = EventLogger(context: context)
        // State Restoration のため、通信オン中は起動直後に Manager を生成する
        manager = PassbyManager(context: context, logger: logger)
        AppServices.manager = manager
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(manager)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: manager.appDidBecomeActive()
            case .background: manager.appDidEnterBackground()
            default: break
            }
        }
    }
}
