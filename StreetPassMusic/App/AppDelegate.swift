import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let centrals = launchOptions?[.bluetoothCentrals] as? [String] ?? []
        let peripherals = launchOptions?[.bluetoothPeripherals] as? [String] ?? []
        let logger = AppServices.manager?.logger
        if centrals.isEmpty && peripherals.isEmpty {
            logger?.log(.lifecycle, .info, "通常起動")
        } else {
            logger?.log(.restore, .info, "Bluetooth 復元による起動 centrals=\(centrals) peripherals=\(peripherals)")
        }
        return true
    }
}
