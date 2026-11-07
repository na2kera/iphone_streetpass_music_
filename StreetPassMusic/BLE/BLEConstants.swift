import CoreBluetooth

/// アプリ固有の UUID。変更した場合は docs/spec.md と README にも記録する。
enum BLEConstants {
    /// 同じアプリの端末を発見するためのサービス UUID
    static let serviceUUID = CBUUID(string: "A6A02DB3-B0B1-451B-92A6-E251F4703E2E")
    /// 相手の曲ペイロードを読み取る characteristic
    static let readCharacteristicUUID = CBUUID(string: "C1098F6B-8A39-422E-9187-0982394DE3EE")
    /// 自分の曲ペイロードを相手に書き込む characteristic
    static let writeCharacteristicUUID = CBUUID(string: "2D0D7632-F468-4C70-A629-CCCAB87459C4")

    static let centralRestoreIdentifier = "com.keranatsuki.streetpassmusic.central"
    static let peripheralRestoreIdentifier = "com.keranatsuki.streetpassmusic.peripheral"

    /// ペイロードの最大バイト数（BLE の read が 1 回で返せる上限）
    static let maxPayloadBytes = 512
    /// 接続開始から交換完了までの上限秒数。超えたら切断して失敗扱い。
    static let exchangeTimeoutSeconds: TimeInterval = 15
    static let protocolVersion = 1
}
