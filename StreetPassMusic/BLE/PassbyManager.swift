import CoreBluetooth
import Foundation
import Observation
import SwiftData

enum SettingsKey {
    static let passbyEnabled = "passbyEnabled"
    static let cooldownMinutes = "cooldownMinutes"
    static let discoveryOnly = "discoveryOnly"
}

/// Central 側の 1 接続分の進行状態
final class PeripheralSession {
    let peripheral: CBPeripheral
    let startedAt = Date()
    var readCharacteristic: CBCharacteristic?
    var writeCharacteristic: CBCharacteristic?
    var receivedPayload: SongPayload?
    var wroteOK = false
    var saved = false
    var timeoutTask: Task<Void, Never>?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

/// すれ違い通信の中心。Central（発見・接続）と Peripheral（発信・GATT 公開）を同時に担う。
/// Core Bluetooth のコールバックはすべて main queue で受け取る。
@MainActor
@Observable
final class PassbyManager: NSObject {
    /// GATT サービスの登録状態
    enum ServiceState {
        case none, adding, added
    }

    // MARK: 観測可能な状態
    private(set) var centralState: CBManagerState = .unknown
    private(set) var peripheralState: CBManagerState = .unknown
    private(set) var isScanning = false
    private(set) var isAdvertising = false
    private(set) var activeSessionCount = 0
    private(set) var restoredCentralAtLaunch = false
    private(set) var restoredPeripheralAtLaunch = false
    /// 短命トークン。重複抑制にのみ使う。起動時に生成し、60 分ごとに作り直す。
    private(set) var sessionToken: String
    private var tokenCreatedAt: Date
    private let tokenLifetime: TimeInterval = 60 * 60

    // MARK: 設定（UserDefaults に永続化）
    private(set) var isEnabled: Bool
    private(set) var cooldownMinutes: Int
    private(set) var discoveryOnly: Bool

    let logger: EventLogger
    private let context: ModelContext

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var serviceState: ServiceState = .none

    // Central 側
    private var sessions: [UUID: PeripheralSession] = [:]
    private var nextAllowedAtByPeripheral: [UUID: Date] = [:]
    /// 失敗時の再試行待ち時間
    private let failureBackoff: TimeInterval = 30
    /// State Restoration で渡された peripheral。poweredOn になってから処理する。
    private var restoredPeripherals: [CBPeripheral] = []
    /// 切断要求を出し、didDisconnect をまだ受けていない peripheral
    private var disconnecting: [UUID: CBPeripheral] = [:]
    /// クールダウン／バックオフ中に発見したため接続しなかった peripheral と、その解除時刻
    private var deferredPeripherals: [UUID: (peripheral: CBPeripheral, next: Date)] = [:]
    /// deferredPeripherals の解除時刻にスキャンをやり直すタスク（同時に 1 つだけ）
    private var rediscoveryTask: Task<Void, Never>?

    // 共通（トークン単位の重複抑制）
    private var lastSavedAtByToken: [String: Date] = [:]

    // Peripheral 側
    private var readServedAtByCentral: [UUID: Date] = [:]
    /// long read の途中で内容が変わらないよう、offset 0 の時点のペイロードを central ごとに保持する
    private var readSnapshots: [UUID: (data: Data, at: Date)] = [:]
    private let readSnapshotLifetime: TimeInterval = 60

    init(context: ModelContext, logger: EventLogger) {
        self.context = context
        self.logger = logger
        self.sessionToken = Self.makeToken()
        self.tokenCreatedAt = Date()
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: SettingsKey.passbyEnabled)
        self.cooldownMinutes = defaults.object(forKey: SettingsKey.cooldownMinutes) as? Int ?? 10
        self.discoveryOnly = defaults.bool(forKey: SettingsKey.discoveryOnly)
        super.init()
        logger.log(.lifecycle, .info, "PassbyManager 初期化 token=\(sessionToken) enabled=\(isEnabled)")
        if isEnabled {
            createManagersIfNeeded()
        }
    }

    private static func makeToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    // MARK: - 設定変更

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.passbyEnabled)
        logger.log(.lifecycle, .info, "すれ違い通信 \(enabled ? "オン" : "オフ")")
        if enabled {
            createManagersIfNeeded()
            startScanIfPossible()
            startAdvertisingIfPossible()
        } else {
            stopAll()
        }
    }

    func setCooldownMinutes(_ minutes: Int) {
        cooldownMinutes = max(0, min(30, minutes))
        UserDefaults.standard.set(cooldownMinutes, forKey: SettingsKey.cooldownMinutes)
        logger.log(.lifecycle, .info, "クールダウン変更 \(cooldownMinutes)分")
    }

    func setDiscoveryOnly(_ value: Bool) {
        discoveryOnly = value
        UserDefaults.standard.set(value, forKey: SettingsKey.discoveryOnly)
        logger.log(.lifecycle, .info, "発見のみモード \(value ? "オン" : "オフ")")
        if value {
            // 進行中の交換は打ち切る（広告は発見率計測のため継続する）
            for session in Array(sessions.values) {
                finishSession(session, success: false, reason: "discoveryOnly")
            }
        } else if isEnabled {
            // AllowDuplicates=false のため、発見のみ中に見た相手はスキャンをやり直さないと再報告されない
            restartScan()
        }
    }

    /// 登録曲が変わったときに呼ぶ（Peripheral 側は read のたびに最新を返すので特別な処理は不要）
    func songDidChange() {
        logger.log(.lifecycle, .info, "登録曲を更新")
    }

    // MARK: - ライフサイクル

    func appDidBecomeActive() {
        logger.log(.lifecycle, .info, "前面に復帰")
        if isEnabled {
            restartScan()
            purgeExpiredDeferred()
        }
    }

    func appDidEnterBackground() {
        logger.log(.lifecycle, .info, "バックグラウンドへ")
    }

    /// 手動でスキャン・広告をやり直す（デバッグ用）。サービス追加に失敗していた場合も再試行する。
    func restartAll() {
        guard isEnabled else { return }
        logger.log(.lifecycle, .info, "手動再起動")
        restartScan()
        stopAdvertising()
        startAdvertisingIfPossible()
    }

    private func createManagersIfNeeded() {
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionRestoreIdentifierKey: BLEConstants.centralRestoreIdentifier,
                          CBCentralManagerOptionShowPowerAlertKey: true]
            )
            logger.log(.lifecycle, .info, "CBCentralManager 生成")
        }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [CBPeripheralManagerOptionRestoreIdentifierKey: BLEConstants.peripheralRestoreIdentifier]
            )
            logger.log(.lifecycle, .info, "CBPeripheralManager 生成")
        }
    }

    private func stopAll() {
        if isScanning { central?.stopScan() }
        isScanning = false
        logger.log(.scan, .stopped, "スキャン停止")
        rediscoveryTask?.cancel()
        rediscoveryTask = nil
        deferredPeripherals.removeAll()
        for session in sessions.values {
            session.timeoutTask?.cancel()
            if let payload = session.receivedPayload, !session.saved {
                session.saved = true
                saveReceived(payload, role: .central, status: .received,
                             peer: shortID(session.peripheral.identifier), failureReason: "ユーザーが通信をオフ")
            }
            requestDisconnect(session.peripheral)
        }
        sessions.removeAll()
        activeSessionCount = 0
        // 開始要求中（isAdvertising がまだ false）の広告も止める
        stopAdvertising()
        if serviceState != .none {
            peripheralManager?.removeAllServices()
            serviceState = .none
        }
        readSnapshots.removeAll()
    }

    // MARK: - 自分の曲ペイロード

    private func currentPayloadData() -> Data {
        if Date().timeIntervalSince(tokenCreatedAt) > tokenLifetime {
            let old = sessionToken
            sessionToken = Self.makeToken()
            tokenCreatedAt = Date()
            logger.log(.lifecycle, .info, "セッショントークン更新 \(old) -> \(sessionToken)")
        }
        var descriptor = FetchDescriptor<MySong>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let song = (try? context.fetch(descriptor))?.first
        let payload = SongPayload(
            version: BLEConstants.protocolVersion,
            sessionToken: sessionToken,
            song: .init(
                title: song?.title ?? "（未登録）",
                artist: song?.artist ?? "",
                url: SongURLValidator.sanitized(song?.url)
            )
        )
        return payload.encodedWithinLimit()
    }

    // MARK: - 受信の保存（共通）

    private var cooldownInterval: TimeInterval { TimeInterval(cooldownMinutes * 60) }

    /// 同一トークンの二重保存を防ぐ窓。クールダウン 0 分でも、同時接続（Central と Peripheral の両経路）による重複は防ぐ。
    private var tokenDedupWindow: TimeInterval {
        max(cooldownInterval, BLEConstants.exchangeTimeoutSeconds * 2)
    }

    private func isTokenInCooldown(_ token: String) -> Bool {
        guard let last = lastSavedAtByToken[token] else { return false }
        return Date().timeIntervalSince(last) < tokenDedupWindow
    }

    /// 受信した曲を履歴に保存する。クールダウン中なら保存せず false を返す。
    @discardableResult
    private func saveReceived(_ payload: SongPayload, role: PassbyEvent.Role, status: PassbyEvent.Status, peer: String, failureReason: String?) -> Bool {
        if isTokenInCooldown(payload.sessionToken) {
            logger.log(.cooldown, .skipped, "トークン \(payload.sessionToken) はクールダウン中のため履歴に追加しない", peer: peer)
            return false
        }
        let event = PassbyEvent(
            receivedTitle: payload.song.title,
            receivedArtist: payload.song.artist,
            receivedURL: SongURLValidator.sanitized(payload.song.url),
            status: status,
            role: role,
            peerToken: payload.sessionToken,
            failureReason: failureReason
        )
        context.insert(event)
        do {
            try context.save()
            lastSavedAtByToken[payload.sessionToken] = Date()
            logger.log(.save, .ok, "履歴保存 status=\(status.rawValue) role=\(role.rawValue) token=\(payload.sessionToken)", peer: peer)
            return true
        } catch {
            logger.log(.save, .failed, "履歴保存失敗: \(error.localizedDescription)", peer: peer)
            return false
        }
    }

    // MARK: - Central: スキャン

    private func startScanIfPossible() {
        guard isEnabled, let central, central.state == .poweredOn else { return }
        guard !isScanning else { return }
        central.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        logger.log(.scan, .started, "スキャン開始 service=\(BLEConstants.serviceUUID.uuidString.prefix(8))")
    }

    private func restartScan() {
        guard let central, central.state == .poweredOn else { return }
        if isScanning {
            central.stopScan()
            isScanning = false
        }
        startScanIfPossible()
    }

    private func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8))
    }

    // MARK: - Central: クールダウン明けの再発見

    /// AllowDuplicates=false のスキャンでは、クールダウン中に一度捨てた相手は再通知されない。
    /// そこで最も早い解除時刻にスキャンをやり直す。
    /// 注意: バックグラウンドでは Task.sleep が大きく遅れる（またはアプリが停止している）可能性がある。
    /// その場合は前面復帰時の appDidBecomeActive か、次の finishSession でのスキャン再開が先に効く。
    private func scheduleRediscoveryIfNeeded() {
        guard rediscoveryTask == nil, let earliest = deferredPeripherals.values.map(\.next).min() else { return }
        let delay = max(0, earliest.timeIntervalSinceNow) + 0.5
        logger.log(.scan, .info, String(format: "再発見を予約 %.0f秒後（背景ではタイマーが遅れる可能性あり）", delay))
        rediscoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.rediscoveryTask = nil
            guard self.isEnabled else { return }
            self.restartScan()
            self.logger.log(.scan, .started, "再発見のため再開")
            self.purgeExpiredDeferred()
            self.scheduleRediscoveryIfNeeded()
        }
    }

    /// 解除時刻を過ぎた deferred エントリを捨てる（スキャン再開後に呼ぶ）
    private func purgeExpiredDeferred() {
        let now = Date()
        deferredPeripherals = deferredPeripherals.filter { $0.value.next > now }
    }

    // MARK: - Central: セッション

    private func beginSession(with peripheral: CBPeripheral) {
        guard let central else { return }
        let session = PeripheralSession(peripheral: peripheral)
        sessions[peripheral.identifier] = session
        activeSessionCount = sessions.count
        peripheral.delegate = self
        let peer = shortID(peripheral.identifier)
        logger.log(.connect, .started, "接続開始", peer: peer)
        central.connect(peripheral, options: nil)
        armTimeout(for: session)
    }

    /// 交換タイムアウトを設定する（通常接続と復元セッションで共用）
    private func armTimeout(for session: PeripheralSession) {
        session.timeoutTask?.cancel()
        let peer = shortID(session.peripheral.identifier)
        session.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BLEConstants.exchangeTimeoutSeconds))
            guard !Task.isCancelled, let self else { return }
            self.logger.log(.error, .failed, "交換タイムアウト(\(Int(BLEConstants.exchangeTimeoutSeconds))秒)", peer: peer)
            self.finishSession(session, success: false, reason: "timeout")
        }
    }

    /// 切断を要求し、didDisconnect を受けるまで disconnecting に保持する
    private func requestDisconnect(_ peripheral: CBPeripheral) {
        guard peripheral.state != .disconnected else { return }
        disconnecting[peripheral.identifier] = peripheral
        central?.cancelPeripheralConnection(peripheral)
    }

    /// セッションを終了する。受信済みで未保存なら保存し、切断してスキャンを再開する。
    /// 成功は「相手の曲を受信」かつ「自分の曲の write 成功」の両方を満たす場合のみ。
    private func finishSession(_ session: PeripheralSession, success requestedSuccess: Bool, reason: String?) {
        let id = session.peripheral.identifier
        // タイムアウトと切断などで二重に呼ばれても 1 回だけ処理する
        guard sessions[id] === session else { return }
        let peer = shortID(id)
        session.timeoutTask?.cancel()
        session.timeoutTask = nil

        if let payload = session.receivedPayload, !session.saved {
            session.saved = true
            let status: PassbyEvent.Status = session.wroteOK ? .exchanged : .received
            saveReceived(payload, role: .central, status: status, peer: peer,
                         failureReason: session.wroteOK ? nil : (reason ?? "write未完了"))
        }

        let success = requestedSuccess && session.receivedPayload != nil && session.wroteOK
        let elapsed = Date().timeIntervalSince(session.startedAt)
        if success {
            nextAllowedAtByPeripheral[id] = Date().addingTimeInterval(cooldownInterval)
            logger.log(.disconnect, .ok, String(format: "交換完了 %.2f秒", elapsed), peer: peer)
        } else {
            nextAllowedAtByPeripheral[id] = Date().addingTimeInterval(failureBackoff)
            var why = reason
            if why == nil {
                if session.receivedPayload == nil { why = "read failed" } else if !session.wroteOK { why = "write failed" }
            }
            logger.log(.disconnect, .failed, String(format: "交換失敗 %.2f秒 reason=%@", elapsed, why ?? "-"), peer: peer)
        }

        requestDisconnect(session.peripheral)
        sessions[id] = nil
        activeSessionCount = sessions.count
        restartScan()
        purgeExpiredDeferred()
    }

    /// 復元された peripheral をセッションとして引き継ぐ（Central が poweredOn になってから呼ぶ）
    private func resumeRestoredPeripherals() {
        let restored = restoredPeripherals
        restoredPeripherals.removeAll()
        for peripheral in restored {
            let id = peripheral.identifier
            let peer = shortID(id)
            guard isEnabled, !discoveryOnly, sessions[id] == nil else {
                logger.log(.restore, .skipped, "復元 peripheral を破棄（通信オフ・発見のみ・処理中）", peer: peer)
                requestDisconnect(peripheral)
                continue
            }
            switch peripheral.state {
            case .connected:
                let session = PeripheralSession(peripheral: peripheral)
                sessions[id] = session
                activeSessionCount = sessions.count
                peripheral.delegate = self
                armTimeout(for: session)
                if let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.serviceUUID }) {
                    logger.log(.restore, .info, "復元セッション再開（characteristic 探索から）", peer: peer)
                    peripheral.discoverCharacteristics([BLEConstants.readCharacteristicUUID, BLEConstants.writeCharacteristicUUID], for: service)
                } else {
                    logger.log(.restore, .info, "復元セッション再開（サービス探索から）", peer: peer)
                    peripheral.discoverServices([BLEConstants.serviceUUID])
                }
            case .connecting:
                let session = PeripheralSession(peripheral: peripheral)
                sessions[id] = session
                activeSessionCount = sessions.count
                peripheral.delegate = self
                armTimeout(for: session)
                logger.log(.restore, .info, "復元セッション再開（接続待ち）", peer: peer)
            default:
                logger.log(.restore, .skipped, "復元 peripheral を破棄 state=\(peripheral.state.rawValue)", peer: peer)
            }
        }
    }

    // MARK: - Peripheral: 広告

    private func startAdvertisingIfPossible() {
        guard isEnabled, let pm = peripheralManager, pm.state == .poweredOn else { return }
        switch serviceState {
        case .none:
            let readChar = CBMutableCharacteristic(
                type: BLEConstants.readCharacteristicUUID,
                properties: [.read],
                value: nil,
                permissions: [.readable]
            )
            let writeChar = CBMutableCharacteristic(
                type: BLEConstants.writeCharacteristicUUID,
                properties: [.write],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
            service.characteristics = [readChar, writeChar]
            pm.add(service)
            serviceState = .adding
            logger.log(.advertise, .info, "サービス追加")
            return // didAdd 成功後に広告を開始する
        case .adding:
            return
        case .added:
            break
        }
        guard !isAdvertising else { return }
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "StreetPassMusic",
        ])
        logger.log(.advertise, .started, "広告開始要求")
    }

    /// 広告を止める。開始要求中で isAdvertising がまだ false の場合も止めるため、常に stopAdvertising を呼ぶ。
    private func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        if isAdvertising {
            logger.log(.advertise, .stopped, "広告停止")
        }
        isAdvertising = false
    }
}

// MARK: - CBCentralManagerDelegate

extension PassbyManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = central.state
        logger.log(.lifecycle, .info, "Central state=\(central.state.label)")
        if central.state == .poweredOn {
            resumeRestoredPeripherals()
            restartScan()
        } else {
            isScanning = false
            if !restoredPeripherals.isEmpty {
                logger.log(.restore, .skipped, "Central が利用不可のため復元 peripheral \(restoredPeripherals.count) 件を破棄")
                restoredPeripherals.removeAll()
            }
            disconnecting.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        restoredCentralAtLaunch = true
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? []
        logger.log(.restore, .info, "Central 復元（Bluetooth による起動）peripherals=\(peripherals.count) scanServices=\(scanServices.count)")
        if !scanServices.isEmpty { isScanning = true }
        for peripheral in peripherals {
            peripheral.delegate = self
            logger.log(.restore, .info, "復元された peripheral state=\(peripheral.state.rawValue)", peer: shortID(peripheral.identifier))
        }
        // セッション化は poweredOn を待ってから行う
        restoredPeripherals = peripherals
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let peer = shortID(id)
        guard isEnabled else {
            logger.log(.discovered, .skipped, "通信オフのため発見を無視", peer: peer)
            return
        }
        let overflow = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?.isEmpty == false
        logger.log(.discovered, .ok, "発見 rssi=\(RSSI) overflow=\(overflow)", peer: peer)

        if discoveryOnly {
            logger.log(.connect, .skipped, "発見のみモードのため接続しない", peer: peer)
            return
        }
        if sessions[id] != nil {
            return
        }
        if disconnecting[id] != nil || peripheral.state != .disconnected {
            logger.log(.connect, .skipped, "切断待ち state=\(peripheral.state.rawValue)", peer: peer)
            return
        }
        if let next = nextAllowedAtByPeripheral[id], next > Date() {
            logger.log(.cooldown, .skipped, "クールダウン中 残り\(Int(next.timeIntervalSinceNow))秒", peer: peer)
            deferredPeripherals[id] = (peripheral, next)
            scheduleRediscoveryIfNeeded()
            return
        }
        deferredPeripherals[id] = nil
        beginSession(with: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peer = shortID(peripheral.identifier)
        logger.log(.connect, .ok, "接続成功", peer: peer)
        guard sessions[peripheral.identifier] != nil else {
            requestDisconnect(peripheral)
            return
        }
        peripheral.discoverServices([BLEConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let peer = shortID(peripheral.identifier)
        disconnecting[peripheral.identifier] = nil
        logger.log(.connect, .failed, "接続失敗: \(error?.localizedDescription ?? "-")", peer: peer)
        if let session = sessions[peripheral.identifier] {
            finishSession(session, success: false, reason: "connect failed")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peer = shortID(peripheral.identifier)
        disconnecting[peripheral.identifier] = nil
        if let session = sessions[peripheral.identifier] {
            logger.log(.disconnect, error == nil ? .info : .failed, "切断: \(error?.localizedDescription ?? "正常")", peer: peer)
            finishSession(session, success: false, reason: "disconnected before completion")
        } else {
            logger.log(.disconnect, .info, "切断(処理済み)", peer: peer)
        }
    }
}

// MARK: - CBPeripheralDelegate（Central 側で接続した相手の操作）

extension PassbyManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let peer = shortID(peripheral.identifier)
        guard let session = sessions[peripheral.identifier] else { return }
        if let error {
            logger.log(.error, .failed, "サービス探索失敗: \(error.localizedDescription)", peer: peer)
            finishSession(session, success: false, reason: "discoverServices")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.serviceUUID }) else {
            logger.log(.error, .failed, "対象サービスなし", peer: peer)
            finishSession(session, success: false, reason: "no service")
            return
        }
        peripheral.discoverCharacteristics([BLEConstants.readCharacteristicUUID, BLEConstants.writeCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let peer = shortID(peripheral.identifier)
        guard let session = sessions[peripheral.identifier] else { return }
        if let error {
            logger.log(.error, .failed, "characteristic 探索失敗: \(error.localizedDescription)", peer: peer)
            finishSession(session, success: false, reason: "discoverCharacteristics")
            return
        }
        session.readCharacteristic = service.characteristics?.first { $0.uuid == BLEConstants.readCharacteristicUUID }
        session.writeCharacteristic = service.characteristics?.first { $0.uuid == BLEConstants.writeCharacteristicUUID }
        guard let readChar = session.readCharacteristic, session.writeCharacteristic != nil else {
            logger.log(.error, .failed, "必要な characteristic なし", peer: peer)
            finishSession(session, success: false, reason: "no characteristics")
            return
        }
        logger.log(.read, .started, "read 要求 maxWrite=\(peripheral.maximumWriteValueLength(for: .withResponse))", peer: peer)
        peripheral.readValue(for: readChar)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let peer = shortID(peripheral.identifier)
        guard let session = sessions[peripheral.identifier] else { return }
        if let error {
            logger.log(.read, .failed, "read 失敗: \(error.localizedDescription)", peer: peer)
            proceedToWrite(session, peer: peer)
            return
        }
        guard let data = characteristic.value else {
            logger.log(.read, .failed, "read 値なし", peer: peer)
            proceedToWrite(session, peer: peer)
            return
        }
        do {
            let payload = try SongPayload.decode(data)
            session.receivedPayload = payload
            logger.log(.read, .ok, "read 成功 \(data.count)bytes token=\(payload.sessionToken)", peer: peer)
        } catch {
            logger.log(.read, .failed, "デコード失敗 \(data.count)bytes: \(error.localizedDescription)", peer: peer)
        }
        proceedToWrite(session, peer: peer)
    }

    private func proceedToWrite(_ session: PeripheralSession, peer: String) {
        guard let writeChar = session.writeCharacteristic else {
            finishSession(session, success: false, reason: "no write characteristic")
            return
        }
        let data = currentPayloadData()
        logger.log(.write, .started, "write 要求 \(data.count)bytes", peer: peer)
        session.peripheral.writeValue(data, for: writeChar, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let peer = shortID(peripheral.identifier)
        guard let session = sessions[peripheral.identifier] else { return }
        if let error {
            logger.log(.write, .failed, "write 失敗: \(error.localizedDescription)", peer: peer)
            finishSession(session, success: false, reason: "write failed")
            return
        }
        session.wroteOK = true
        logger.log(.write, .ok, "write 成功", peer: peer)
        // 受信できていなければ finishSession 側で失敗（片側のみ成功）として扱う
        finishSession(session, success: true, reason: session.receivedPayload == nil ? "read failed" : nil)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension PassbyManager: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        peripheralState = peripheral.state
        logger.log(.lifecycle, .info, "Peripheral state=\(peripheral.state.label)")
        if peripheral.state == .poweredOn {
            startAdvertisingIfPossible()
        } else {
            isAdvertising = false
            serviceState = .none
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        restoredPeripheralAtLaunch = true
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        let adData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any]
        logger.log(.restore, .info, "Peripheral 復元（Bluetooth による起動）services=\(services.count) advertising=\(adData != nil)")
        // 追加済みと分かっている場合のみ、poweredOn で即時広告できる
        if services.contains(where: { $0.uuid == BLEConstants.serviceUUID }) {
            serviceState = .added
        }
        if adData != nil { isAdvertising = true }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard serviceState == .adding else {
            logger.log(.advertise, .info, "サービス追加完了通知を無視（状態が変わっている）")
            return
        }
        if let error {
            serviceState = .none
            logger.log(.advertise, .failed, "サービス追加失敗: \(error.localizedDescription)（再起動で再試行）")
        } else {
            serviceState = .added
            logger.log(.advertise, .ok, "サービス追加完了")
            startAdvertisingIfPossible()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            isAdvertising = false
            logger.log(.advertise, .failed, "広告開始失敗: \(error.localizedDescription)")
        } else if !isEnabled {
            peripheral.stopAdvertising()
            isAdvertising = false
            logger.log(.advertise, .stopped, "通信オフのため開始直後に広告停止")
        } else {
            isAdvertising = true
            logger.log(.advertise, .ok, "広告中")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let peer = shortID(request.central.identifier)
        guard isEnabled else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            logger.log(.read, .skipped, "通信オフのため read 拒否", peer: peer)
            return
        }
        guard request.characteristic.uuid == BLEConstants.readCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        if discoveryOnly {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            logger.log(.read, .skipped, "発見のみモードのため read 拒否", peer: peer)
            return
        }

        let centralID = request.central.identifier
        let now = Date()
        let data: Data
        if request.offset == 0 {
            // 新しい read の開始。古いスナップショットを掃除してから取り直す
            readSnapshots = readSnapshots.filter { now.timeIntervalSince($0.value.at) <= readSnapshotLifetime }
            data = currentPayloadData()
            readSnapshots[centralID] = (data, now)
        } else if let snapshot = readSnapshots[centralID] {
            data = snapshot.data
        } else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            logger.log(.read, .failed, "read 応答: スナップショットなし offset=\(request.offset)", peer: peer)
            return
        }
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            logger.log(.read, .failed, "read 応答: 不正なオフセット \(request.offset)", peer: peer)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
        readServedAtByCentral[centralID] = now
        logger.log(.read, .ok, "read 応答 \(data.count)bytes offset=\(request.offset) mtu=\(request.central.maximumUpdateValueLength)", peer: peer)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        let peer = shortID(first.central.identifier)

        // 要求が複数でも応答は first に 1 回だけ返す
        guard isEnabled else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            logger.log(.write, .skipped, "通信オフのため write 拒否", peer: peer)
            return
        }
        guard requests.allSatisfy({ $0.characteristic.uuid == BLEConstants.writeCharacteristicUUID }) else {
            peripheral.respond(to: first, withResult: .attributeNotFound)
            logger.log(.write, .failed, "write 受信: 対象外の characteristic を含む", peer: peer)
            return
        }
        if discoveryOnly {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            logger.log(.write, .skipped, "発見のみモードのため write 拒否", peer: peer)
            return
        }

        // 分割書き込み（long write）: offset 0 から隙間なく連続していることを確認して結合する
        let sorted = requests.sorted { $0.offset < $1.offset }
        var buffer = Data()
        for req in sorted {
            guard req.offset == buffer.count else {
                peripheral.respond(to: first, withResult: .invalidOffset)
                logger.log(.write, .failed, "write 受信: 不連続なオフセット \(req.offset)（期待値 \(buffer.count)）", peer: peer)
                return
            }
            buffer.append(req.value ?? Data())
            guard buffer.count <= BLEConstants.maxPayloadBytes else {
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                logger.log(.write, .failed, "write 受信: \(BLEConstants.maxPayloadBytes)bytes 超過", peer: peer)
                return
            }
        }

        do {
            let payload = try SongPayload.decode(buffer)
            peripheral.respond(to: first, withResult: .success)
            logger.log(.write, .ok, "write 受信 \(buffer.count)bytes(\(requests.count)req) token=\(payload.sessionToken)", peer: peer)

            let servedRecently: Bool = {
                guard let at = readServedAtByCentral[first.central.identifier] else { return false }
                return Date().timeIntervalSince(at) < BLEConstants.exchangeTimeoutSeconds * 2
            }()
            saveReceived(payload, role: .peripheral, status: servedRecently ? .exchanged : .received, peer: peer,
                         failureReason: servedRecently ? nil : "相手からの read 未確認")
        } catch {
            peripheral.respond(to: first, withResult: .unlikelyError)
            logger.log(.write, .failed, "write 受信デコード失敗 \(buffer.count)bytes: \(error.localizedDescription)", peer: peer)
        }
    }
}

extension CBManagerState {
    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "?"
        }
    }

    var japanese: String {
        switch self {
        case .unknown: return "不明"
        case .resetting: return "リセット中"
        case .unsupported: return "非対応"
        case .unauthorized: return "権限なし"
        case .poweredOff: return "Bluetooth オフ"
        case .poweredOn: return "利用可能"
        @unknown default: return "?"
        }
    }
}
