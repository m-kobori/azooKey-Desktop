# 履歴保存（SQLite）設計 — KiwiHistory (NT-832)

確定した「読み→表記」ペアをローカル SQLite に保存し、頻度と文脈に基づく予測変換の基盤を作る。

## アーキテクチャ上の前提（重要）

azooKey-Desktop は **2プロセス構成**（IMK ホスト `azooKeyMac` と、変換を担う別プロセス `ConverterServer`）で、XPC 通信する。**読み（yomi）を含む完全な `Candidate` はサーバ側（`Core` パッケージ）にしか存在しない**（XPC 境界を越えるのは表記テキストのみ）。

したがって KiwiHistory は **`Core` パッケージ内**に実装し、`ConverterServer` プロセスで動作させる。

## 依存

- `GRDB.swift`（型安全・Swift Concurrency 対応の SQLite ラッパー）を `Core/Package.swift` に追加。
  - `dependencies` に `.package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0")`
  - `Core` ターゲットの `dependencies` に `.product(name: "GRDB", package: "GRDB.swift")`
  - `Core` は `ConverterServer` からも参照されるため、GRDB はアプリ・サーバ両プロセスにリンクされる（履歴が必要なサーバ側で使える）。

## モジュール構成

```
Core/Sources/Core/KiwiHistory/
├── HistoryEntry.swift      # GRDB レコード（テーブル行）
├── HistoryCandidate.swift  # predict の返り値
└── HistoryManager.swift    # DB 接続・record/predict/decay
```

## DB スキーマ（`history` テーブル）

| カラム | 型 | 説明 |
|---|---|---|
| id | INTEGER PK | 自動採番 |
| reading | TEXT NOT NULL | 読み（**ひらがなに正規化**） |
| surface | TEXT NOT NULL | 確定文字列 |
| leftContext | TEXT NOT NULL default '' | 直前の文脈 |
| rightContext | TEXT | 直後の文脈（任意） |
| timestamp | DATETIME NOT NULL | 最終確定時刻 |
| frequency | DOUBLE NOT NULL default 1.0 | 頻度スコア |
| source | TEXT NOT NULL default 'ime' | 由来 |

インデックス:
- `reading`（前方一致検索の高速化）
- `(reading, surface)` **UNIQUE**（record の加算更新のため）

マイグレーションは `DatabaseMigrator` で管理する。

## 保存場所（プライバシー）

App Sandbox コンテナ配下:

```
<containerURL>/Library/Application Support/KiwiHistory/history.sqlite
```

`containerURL` は `SegmentsManager` が保持しているものを使う。ネットワークには一切送信しない。

## API（`HistoryManager`）

```swift
init(databaseURL: URL) throws                 // テスト用
init(containerURL: URL) throws                // 本番（Sandbox 配下）
func record(reading:surface:leftContext:rightContext:source:at:)
func predict(reading:leftContext:limit:) -> [HistoryCandidate]
func decayAll(by:)                            // 頻度減衰＋剪定
func count() -> Int
func clear()
```

- **record**: 同じ `(reading, surface)` があれば `frequency += 1`、文脈・時刻を更新。無ければ挿入。
- **predict**: `reading` の前方一致で取得し、`frequency × (1 + 文脈類似度)` で再ランクして上位 `limit` 件。
  - 文脈類似度は左文脈の**末尾一致長**を短い方の長さで正規化した [0,1]。
- **decayAll**: 全行 `frequency *= factor`（例 0.9）。`frequency < 0.05` の行は削除。
  - 毎日1回程度の実行を想定（スケジューラは別途）。

## 確定フックの統合

確定は最終的に `SegmentsManager.prefixCandidateCommited(_:leftSideContext:)` に集約される
（ライブ変換の `commitMarkedText` もこの関数を経由する）。ここに記録を差し込む。

```swift
// SegmentsManager.swift
self.recordHistoryIfNeeded(candidate, leftSideContext: leftSideContext)
```

- 読み: `candidate.data.map(\.ruby).joined().toHiragana()`（ruby はカタカナのためひらがなへ正規化）
- 表記: `candidate.text`
- **キャンセル / Backspace 確定では呼ばれない**（この関数は正規の確定時のみ通る）ので、誤変換を学習しない。
- DB 書き込みで確定処理をブロックしないよう、値をコピーして `Task.detached(priority: .utility)` で実行する。
- `Config.KiwiHistoryEnabled`（デフォルト ON）が false のときは記録しない。

## 設定

`Config.KiwiHistoryEnabled`（`BoolConfigItem`、デフォルト `true`）。
UI に「変換履歴を保存（予測変換の基盤）」トグルと「履歴をクリア」を追加できる（`HistoryManager.clear()`）。

## エラー方針

履歴保存はベストエフォート。DB 初期化・書き込み・読み込みの失敗は握りつぶし（デバッグログのみ）、
入力体験を絶対に妨げない。`HistoryManager` は `@unchecked Sendable`（内部の `DatabaseQueue` がシリアルアクセスを保証）。

## テスト

`Core/Tests/CoreTests/KiwiHistoryTests/HistoryManagerTests.swift`（swift-testing）:
- record→predict で最頻出が先頭
- 同一ペアの加算更新（レコードは1件）
- 前方一致
- 文脈類似での優先
- decay による剪定
- 空入力の無視
- `contextSimilarity` / `escapeLike` のユニットテスト

```bash
cd Core && swift test --filter KiwiHistory
```

## 今後の拡張

- `decayAll` を毎日実行するスケジューリング（アプリ起動時に最終実行日を見て1回など）
- `predict` 結果を候補ウィンドウへ差し込む統合（[[llm-revision]] と同様の非同期差し込み経路を共用可能）
- 文脈の n-gram 化によるより高精度な予測
