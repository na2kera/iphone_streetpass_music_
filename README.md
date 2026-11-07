# StreetPass Music（PoC）

Nintendo DS の「すれ違い通信」のように、同じアプリを入れた iPhone 同士が近づくと BLE でお気に入り曲（曲名・アーティスト・URL）を自動交換するアプリの PoC。

仕様: [docs/spec.md](docs/spec.md)

## 環境

| 項目 | 値 |
|---|---|
| 対応 OS | iOS 26.0 以上（検証機は iPhone 14 × 2、iOS 27.0.1） |
| 言語 / UI | Swift 5 言語モード + SwiftUI、SwiftData |
| プロジェクト生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml`） |
| Bundle ID | `com.keranatsuki.streetpassmusic` |

## ビルド手順

```sh
brew install xcodegen
xcodegen generate
open StreetPassMusic.xcodeproj
```

1. Xcode で `StreetPassMusic` ターゲットの Signing & Capabilities を開き、Team を選ぶ（Personal Team 可。7 日で期限切れになるので再インストールする）。
2. iPhone を接続し、実機を選んで Run。**シミュレータでは BLE が動かない**。
3. 初回起動時に Bluetooth の許可ダイアログが出る。

`.xcodeproj` は git 管理していない。`project.yml` を変更したら `xcodegen generate` を再実行する。

## 使い方

1. 「曲登録」タブで曲名・アーティスト（任意で https URL）を保存する。
2. 「ホーム」タブで「すれ違い通信」をオンにする。
3. もう 1 台でも同じ手順を行い、近づける。
4. 「履歴」タブに相手の曲が表示される。「デバッグ」タブで発見・接続・read/write・保存の各イベントを確認し、JSON Lines で書き出せる。

## BLE プロトコル

| 要素 | UUID |
|---|---|
| Service | `A6A02DB3-B0B1-451B-92A6-E251F4703E2E` |
| Read characteristic（相手の曲を読む） | `C1098F6B-8A39-422E-9187-0982394DE3EE` |
| Write characteristic（自分の曲を書く） | `2D0D7632-F468-4C70-A629-CCCAB87459C4` |

- 各端末は Central（スキャン・接続）と Peripheral（広告・GATT 公開）を同時に担う。
- 発見した側が接続し、read → write → 切断。ACK は省略。
- ペイロードは JSON（UTF-8）で 512 バイト上限。超える場合は URL を落とし、曲名・アーティスト名を切り詰める。
- `sessionToken` はアプリ起動ごとに生成する短命トークンで、重複抑制にのみ使う。
- クールダウン既定 10 分（デバッグ画面で 0〜30 分に変更可）。失敗時は 30 秒のバックオフ。
- `UIBackgroundModes` に `bluetooth-central` / `bluetooth-peripheral` を宣言し、State Restoration の識別子を設定済み。

## 履歴の状態

| 状態 | 意味 |
|---|---|
| 相互交換 | 相手の曲を保存し、かつ自分の曲の送信（write 成功、または相手からの read 応答）も確認できた |
| 受信のみ | 相手の曲は保存したが、自分の曲が届いたかは未確認 |

## Decision Log

| 日付 | 根拠 | 変更 | 影響 | 検証 |
|---|---|---|---|---|
| 2026-11-08 | 仕様書で未確定だった項目を決定 | Swift 5 言語モード、SwiftData、XcodeGen、JSON 512B、ACK 省略、クールダウン 10 分、Background Modes と State Restoration を初期から導入 | 前面・背景を同じビルドで比較できる | 実機 2 台で T-01 から順に実施 |

## 実機テスト結果

未実施。`docs/spec.md` の T-01〜T-12 を実施したらここに結果表を追記する。
