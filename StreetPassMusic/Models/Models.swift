import Foundation
import SwiftData

/// 自分が登録しているお気に入り曲（1件のみ保持する）
@Model
final class MySong {
    var title: String
    var artist: String
    var url: String?
    var updatedAt: Date

    init(title: String, artist: String, url: String?, updatedAt: Date = .now) {
        self.title = title
        self.artist = artist
        self.url = url
        self.updatedAt = updatedAt
    }
}

/// すれ違い履歴。曲を受信できたときだけ作成する。
@Model
final class PassbyEvent {
    enum Status: String, Codable {
        /// 相手の曲を受信・保存できた（自分の曲が相手に届いたかは未確認）
        case received
        /// 受信に加えて、自分の曲の送信（write 成功 or read 応答）も確認できた
        case exchanged
    }

    enum Role: String, Codable {
        case central
        case peripheral
    }

    var id: UUID
    var receivedTitle: String
    var receivedArtist: String
    var receivedURL: String?
    var receivedAt: Date
    var statusRaw: String
    var roleRaw: String
    /// 相手の短命セッショントークン。重複抑制のためだけに使う。
    var peerToken: String
    var failureReason: String?

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .received }
        set { statusRaw = newValue.rawValue }
    }

    var role: Role {
        get { Role(rawValue: roleRaw) ?? .central }
        set { roleRaw = newValue.rawValue }
    }

    init(
        receivedTitle: String,
        receivedArtist: String,
        receivedURL: String?,
        receivedAt: Date = .now,
        status: Status,
        role: Role,
        peerToken: String,
        failureReason: String? = nil
    ) {
        self.id = UUID()
        self.receivedTitle = receivedTitle
        self.receivedArtist = receivedArtist
        self.receivedURL = receivedURL
        self.receivedAt = receivedAt
        self.statusRaw = status.rawValue
        self.roleRaw = role.rawValue
        self.peerToken = peerToken
        self.failureReason = failureReason
    }
}

/// 実験ログ。発見・接続・read/write・保存・エラーなどを時刻付きで記録する。
@Model
final class DebugEvent {
    var timestamp: Date
    /// active / inactive / background。末尾に locked が付く場合は端末ロック中（protected data 利用不可）
    var appState: String
    var eventType: String
    var outcome: String
    var details: String
    /// 相手の識別に使う短い文字列（Peripheral 識別子の先頭 8 文字など）。永続的な個人識別子は入れない。
    var peer: String?

    init(timestamp: Date = .now, appState: String, eventType: String, outcome: String, details: String, peer: String?) {
        self.timestamp = timestamp
        self.appState = appState
        self.eventType = eventType
        self.outcome = outcome
        self.details = details
        self.peer = peer
    }
}
