import Foundation

/// BLE で交換する曲情報。音声ファイルは含めない。
struct SongPayload: Codable, Equatable {
    struct Song: Codable, Equatable {
        var title: String
        var artist: String
        var url: String?
    }

    var version: Int
    var sessionToken: String
    var song: Song

    /// 512 バイト以内に必ず収めてエンコードする（assert ではなく実行時に保証する）。
    /// 1. 曲名・アーティスト名のうち UTF-8 バイト数が大きいほうだけを文字単位で 3/4 に縮める
    /// 2. まだ超過していれば、両方を UTF-8 バイト境界で各 120 バイトに切る
    /// 3. まだ超過していれば URL を落とす
    /// 4. 最後は曲名だけ（200 バイト以内）の最小ペイロード。JSON エスケープで膨らむ場合はさらに半分ずつ切る
    func encodedWithinLimit() -> Data {
        let limit = BLEConstants.maxPayloadBytes
        var payload = self
        var data = payload.encode()
        if data.count <= limit { return data }

        // 1. 大きいほうだけを縮める
        var attempts = 0
        while data.count > limit && attempts < 64 {
            attempts += 1
            if payload.song.title.utf8.count >= payload.song.artist.utf8.count {
                guard payload.song.title.count > 1 else { break }
                payload.song.title = String(payload.song.title.prefix(max(1, payload.song.title.count * 3 / 4)))
            } else {
                guard payload.song.artist.count > 1 else { break }
                payload.song.artist = String(payload.song.artist.prefix(max(1, payload.song.artist.count * 3 / 4)))
            }
            data = payload.encode()
        }
        if data.count <= limit { return data }

        // 2. UTF-8 バイト境界で固定長（各 120 バイト）に切る
        payload.song.title = Self.truncatedUTF8(payload.song.title, maxBytes: 120)
        payload.song.artist = Self.truncatedUTF8(payload.song.artist, maxBytes: 120)
        data = payload.encode()
        if data.count <= limit { return data }

        // 3. URL を落とす
        payload.song.url = nil
        data = payload.encode()
        if data.count <= limit { return data }

        // 4. 曲名のみの最小ペイロード（200 バイト）。エスケープで膨らむ場合は半分ずつ切る
        var minimal = SongPayload(
            version: version,
            sessionToken: Self.truncatedUTF8(sessionToken, maxBytes: 32),
            song: .init(title: Self.truncatedUTF8(song.title, maxBytes: 200), artist: "", url: nil)
        )
        data = minimal.encode()
        while data.count > limit && minimal.song.title.utf8.count > 1 {
            minimal.song.title = Self.truncatedUTF8(minimal.song.title, maxBytes: minimal.song.title.utf8.count / 2)
            data = minimal.encode()
        }
        if data.count > limit || minimal.song.title.trimmingCharacters(in: .whitespaces).isEmpty {
            // 曲名 "?"・32 バイト以下のトークンなら JSON は 100 バイト未満に収まる
            minimal.song.title = "?"
            data = minimal.encode()
        }
        return data
    }

    /// UTF-8 のバイト数で切り詰める。途中で切れたマルチバイト文字（置換文字）は末尾から取り除く。
    static func truncatedUTF8(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var result = String(decoding: Array(s.utf8.prefix(max(0, maxBytes))), as: UTF8.self)
        while result.unicodeScalars.last == "\u{FFFD}" {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private func encode() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) throws -> SongPayload {
        let payload = try JSONDecoder().decode(SongPayload.self, from: data)
        guard payload.version == BLEConstants.protocolVersion else {
            throw PayloadError.unsupportedVersion(payload.version)
        }
        guard !payload.song.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PayloadError.emptyTitle
        }
        return payload
    }

    enum PayloadError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "未対応のプロトコルバージョン: \(v)"
            case .emptyTitle: return "曲名が空"
            }
        }
    }
}

enum SongURLValidator {
    /// https のみ許可する。表示前にも必ず通す。
    static func sanitized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url.absoluteString
    }
}
