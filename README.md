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
cp Local.xcconfig.example Local.xcconfig   # 初回のみ。無いと xcodegen generate が失敗する
xcodegen generate
open StreetPassMusic.xcodeproj
```

1. Team を設定する（Personal Team 可。7 日で期限切れになるので再インストールする）。`Local.xcconfig.example` の `DEVELOPMENT_TEAM` はコメントアウトされていてキーを定義しないので、次のどちらか。
   - Xcode で Team を選ぶ場合: `Local.xcconfig` はコメントアウトのままにして、Signing & Capabilities で Team を選ぶ。`.xcodeproj` に書かれるので、`xcodegen generate` するたびに選び直しになる。
   - CLI（`xcodebuild`）でビルドする場合: `Local.xcconfig` の `// DEVELOPMENT_TEAM = XXXXXXXXXX` の行のコメントを外し、自分の Team ID（10 桁）を書く。`xcodegen generate` し直しても保持される。`Local.xcconfig` は git 管理外。
2. iPhone を接続し、実機を選んで Run。**シミュレータでは BLE が動かない**。
3. 初めて「すれ違い通信」をオンにしたときに Bluetooth の許可ダイアログが出る。

`.xcodeproj` は git 管理していない。`project.yml` を変更したら `xcodegen generate` を再実行する。

環境の注意:

- Xcode 26.6 は iOS 26.5 SDK のみ同梱。iOS 27.0.1 の実機が「not supported」と出る場合は Xcode 27 が必要。
- アプリアイコンは未設定（PoC のため）。

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
- ペイロードは JSON（UTF-8）で 512 バイト上限を実行時に保証する。超える場合は (1) 曲名・アーティスト名のうちバイト数が大きいほうを縮める (2) 各 120 バイトに切る (3) URL を落とす (4) 曲名のみ（200 バイト以内）の順に縮める。入力欄は曲名・アーティスト 100 文字、URL 300 文字まで。
- `sessionToken` は起動時に生成し 60 分ごとに作り直す短命トークンで、重複抑制にのみ使う。同じトークンは `max(クールダウン, 30 秒)` の間は二重に保存しない。
- クールダウン既定 10 分（デバッグ画面で 0〜30 分に変更可）。失敗時は 30 秒のバックオフ。クールダウン中に発見した相手は、解除時刻にスキャンをやり直して再発見する（背景ではタイマーが遅れることがある）。
- Peripheral 側はサービス追加完了（`didAdd`）を待ってから広告する。long read は offset 0 時点のスナップショットを返し、long write は offset が 0 から連続していることと 512 バイト以内であることを検証する。
- 「発見のみ」モードでは接続せず、GATT の read/write も拒否する（広告は継続）。
- 通信オフ後に届いた発見・read/write は無視または拒否する。
- デバッグログは起動時に 7 日より古いものを削除し、5000 件を超える分も古い順に削除する。画面には新しい 300 件だけ表示し、書き出しは全件。
- `UIBackgroundModes` に `bluetooth-central` / `bluetooth-peripheral` を宣言し、State Restoration の識別子を設定済み。

## 履歴の状態

| 状態 | 意味 |
|---|---|
| 相互交換 | 相手の曲を保存し、かつ自分の曲の送信（write 成功、または相手からの read 応答）も確認できた |
| 受信のみ | 相手の曲は保存したが、自分の曲が届いたかは未確認 |

Central 側の交換は「相手の曲の read 成功」と「自分の曲の write 成功」が両方そろったときだけ成功（`disconnect/ok`）とする。片側だけ成功した場合は `disconnect/failed reason=read failed` または `reason=write failed` を記録し、30 秒のバックオフに入る。read だけ成功していれば履歴には「受信のみ」で保存する。

## Decision Log

| 日付 | 根拠 | 変更 | 影響 | 検証 |
|---|---|---|---|---|
| 2026-11-08 | 仕様書で未確定だった項目を決定 | Swift 5 言語モード、SwiftData、XcodeGen、JSON 512B、ACK 省略、クールダウン 10 分、Background Modes と State Restoration を初期から導入 | 前面・背景を同じビルドで比較できる | 実機 2 台で T-01 から順に実施 |
| 2026-11-08 | レビュー第1回（`docs/reviews/2026-11-08-round1.md`、19 項目） | 通信オフ後のコールバック遮断、サービス追加完了後の広告、クールダウン明けの再発見、復元セッションのタイムアウト、セッション終了の冪等化と切断待ち、成功判定を read かつ write に厳密化、トークン重複抑制の最小窓、オフ時の未保存分の保存、発見のみモードで GATT 応答も拒否、long read/write の検証、トークンの 60 分ローテーション、AppDelegate 削除（復元の判別は willRestoreState のログ）、512 バイトの実行時保証と入力上限、DB を開けないときのエラー画面、ログの保持期間と件数上限、曲登録画面の初回のみ読み込み、Team ID を Local.xcconfig へ | 状態遷移の取りこぼしと二重処理が減る。ログの「交換完了」は read と write の両方成功のみになる | シミュレータ・実機向けビルド成功。BLE の挙動は実機 2 台で未検証 |
| 2026-11-08 | レビュー第2回（`docs/reviews/2026-11-08-round2.md`、10 項目） | 切断待ち中はスキャン再開を didDisconnect に任せる（再発見の取りこぼし防止）、再発見予約をより早い期限で取り直す、didAdd を追加中サービスの同一インスタンスで照合、Bluetooth オフ→オンでサービスを二重登録しない、切断待ちを 5 秒で期限切れ、Bluetooth 停止時にセッションを畳む（自分都合の打ち切りはバックオフなし）、交換中はトークンを更新しない、ログ件数上限の過剰削除を修正、`Local.xcconfig.example` を空の Team に | 切断直後や Bluetooth のオンオフ後も相手に再接続できる。ログに `connect/info 切断待ちを期限切れで解除` が増える | シミュレータ・実機向けビルド成功。BLE の挙動は実機 2 台で未検証 |
| 2026-11-08 | レビュー第3回（`docs/reviews/2026-11-08-round3.md`、11 項目） | 切断コールバックが来ない場合も切断待ちの上限時刻に再発見を予約、期限切れ後も接続が残る相手へ切断要求を出し直す、Bluetooth 停止時に破棄する復元 peripheral の接続も切る、成功後の再接続は最短 5 秒空ける、クールダウン変更・通信オフで相手ごとの待ち時間と再発見予約を初期化、トークン更新をセッション開始時にも判定、`scan/started 再発見のため再開` は実際に再開したときだけ記録、`Local.xcconfig.example` の Team 行をコメントアウト、README・テスト手順の補足 | 切断待ちのまま再接続できない状態が続きにくくなる。クールダウン 0 分でも同じ相手への即時再接続ループが起きない | シミュレータ・実機向けビルド成功。BLE の挙動は実機 2 台で未検証 |

## 実機テスト結果

未実施。`docs/spec.md` の T-01〜T-12 を実施したらここに結果表を追記する。
