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

    /// 512 バイトに収まるように曲名・アーティスト名を切り詰めてエンコードする
    func encodedWithinLimit() -> Data {
        var payload = self
        var data = payload.encode()
        var attempts = 0
        while data.count > BLEConstants.maxPayloadBytes && attempts < 20 {
            attempts += 1
            if payload.song.url != nil && attempts == 1 {
                payload.song.url = nil
            } else {
                payload.song.title = String(payload.song.title.prefix(max(1, payload.song.title.count * 3 / 4)))
                payload.song.artist = String(payload.song.artist.prefix(max(1, payload.song.artist.count * 3 / 4)))
            }
            data = payload.encode()
        }
        return data
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
