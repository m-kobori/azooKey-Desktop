# LLM 補正層 設計 — LLMReviser (NT-831)

確定前の変換候補を、読みと左文脈に基づいてローカル LLM で補正・並び替えする層。

## アーキテクチャ上の前提

[[history]] と同じく、読み（yomi）を含む候補はサーバ側（`Core` パッケージ / `ConverterServer` プロセス）にしか存在しない。よって LLMReviser も `Core` 内に実装する。

## LLM 実行方式の選定

| 方式 | 判断 |
|---|---|
| **Zenzai（同梱 gguf）** | ✕ 自由文生成 API が公開されていない。Zenzai は `KanaKanjiConverter` 内部の n-best かな漢字リランカーで、任意プロンプトの生成には使えない。 |
| **Foundation Models（オンデバイス）** | ◎ 既に `Core/Sources/Core/MagicConversion/` に統合済み。macOS 26+ でオンデバイス動作＝プライバシー良好。**既定の第一候補**。 |
| **OpenAI API（クラウド）** | △ 既存統合あり。プライバシー上デフォルトでは使わない。API キー設定時のみ。 |
| llama.cpp / Ollama | 将来拡張。`LLMRevisionBackend` を実装すれば差し込める。 |

**決定**: 新しい推論エンジンは追加しない。既存 `AIClient`（Foundation Models 優先、OpenAI フォールバック）を `LLMRevisionBackend` 越しに再利用する。バックエンドは差し替え可能にし、将来 Zenzai/llama.cpp を自由文生成に使えるようになった時点で追加できる。

## モジュール構成

```
Core/Sources/Core/KiwiLLM/
├── LLMReviser.swift               # 中核（actor）: サニタイズ・キャッシュ・プロンプト・パース・マージ
├── AIClientRevisionBackend.swift  # 既存 AIClient を使うバックエンド実装
└── Debouncer.swift                # 入力中の無駄呼び出しを抑えるデバウンサ
```

`LLMReviser` は `actor` で、キャッシュへの並行アクセスを安全にする。

## API

```swift
protocol LLMRevisionBackend: Sendable {
    var isAvailable: Bool { get }
    func generate(prompt: String) async throws -> String   // モデルの生応答（JSON 想定）
}

actor LLMReviser {
    init(backend:cacheTTL:minimumMeaningfulContextLength:)
    var isAvailable: Bool { get }
    func revise(reading:leftContext:existingCandidates:maxResults:) async throws -> [LLMRevisedCandidate]
    func purgeExpiredCache()
    static func sanitizeContext(_:) -> String
    static func merge(existing:revised:maxResults:) -> [String]
}
```

## サニタイズ方針

LLM に渡す前に、左文脈のセンシティブ情報を正規表現で伏せ字化する。

| 対象 | パターン | 置換 |
|---|---|---|
| URL | `https?://\S+` | `[URL]` |
| メール | `[\w.+-]+@[\w-]+\.[\w.-]+` | `[EMAIL]` |
| ファイルパス | `(?:/[\w.\-]+){2,}/?` | `[PATH]` |
| 長い数字列（4桁+） | `\d{4,}` | `[NUMBER]` |

サニタイズ後、プレースホルダを除いた「意味のある」文字数が閾値（既定 2）未満なら、**文脈を使わずに**補正する（機密情報だけの文脈を漏らさない）。

## プロンプト設計

```
あなたは日本語入力の変換候補を補正するアシスタントです。
前文と読みから、最も自然な表記を最大N個提案してください。
- 出力は必ず JSON オブジェクト1つだけ。前後に説明文やコードフェンスを付けない。
- 形式: {"candidates": ["表記1", "表記2"]}
- 既存候補にない表記を提案してもよい。英語が混じる場合はそのまま尊重する。

前文: <sanitized left context>
読み: きょうは
既存候補: 今日は, 教養は
```

パーサ（`parseCandidates`）は `{"candidates":[...]}` / 素の JSON 配列 / コードフェンス付き のいずれにも対応する。

## キャッシュとデバウンス

- **キャッシュ**: キー `(sanitizedReading, sanitizedLeftContext, maxResults)`、TTL 既定 600 秒（10 分）。同じ入力の再推論を避ける。`purgeExpiredCache()` で掃除。
- **デバウンス**: `Debouncer`（既定 80ms）。入力中の連続変換で最後の1回だけ実行。確定・カーソル移動で `cancel()`。
- **キャンセル**: `revise` は `Task.checkCancellation()` を挟む。進行中の呼び出しは確定・移動でキャンセルする。

## 既存変換エンジンとの接続（統合方針・**配線済み 2026-07-20**）

非同期のため、**辞書候補を先に表示し、LLM 候補を後から差し込む**。実装は履歴予測（[[history]]）の候補差し込みと同じパターンを踏襲する。

1. `SegmentsManager.updateRawCandidate` で辞書候補 `rawCandidates` を生成・表示（従来どおり）。末尾で `scheduleLLMRevision(leftSideContext:)` を呼ぶ。
2. `scheduleLLMRevision`: `Config.KiwiLLMReviserEnabled`（デフォルト **OFF**）かつ `llmReviser != nil`、読み 2 文字以上のときのみ起動。**MainActor 隔離の `Task`（`llmRevisionTask`）を打鍵ごとに張り替えてデバウンス**（150ms sleep→前回はキャンセル）。closure が MainActor 隔離なので非 Sendable の `self` を安全に触れる（`Debouncer` actor は @Sendable closure に self を捕捉できず不採用）。
3. `LLMReviser.revise(reading: convertTarget, leftContext: getCleanLeftSideContext(...), existingCandidates: <辞書候補の上位8表記>, maxResults: 3)` を非同期実行。完了時、読みが変わっていなければ結果を `Candidate` 化して `llmRevisedCandidates` に格納（`llmRevisedTarget` に対象読みを記録）。
4. `rawCandidatesList` が「履歴候補（先頭）＋辞書候補＋LLM 補正候補（末尾）」を dedup して結合。LLM は `llmRevisedTarget == convertTarget` のときのみ有効。
5. ユーザーが LLM 候補を選んだら [[history]] に保存される（確定フックは共通）。

### 予測バーへの併記（B・非同期 await 方式・**実装済み 2026-07-21**）

ユーザー要望「変換前に、履歴予測と並べて LLM 補正も出したい」に対応。XPC はキーイベント応答がプル型だが、**replaceSuggestion と同じ非同期リクエスト/完了コールバック機構**（`ConverterServerClient.sendIfSessionOpen(_:completion:)`）を使えば「サーバが LLM を await してから結果入り snapshot を返す」ことができる。キー処理自体はブロックしない。

フロー:
1. クライアント `handleKeyEventWithConverterServer` の末尾で `scheduleLLMPredictionRefreshIfNeeded()` を呼ぶ。composing 中かつ `KiwiLLMReviserEnabled` のときのみ。
2. 200ms デバウンス（`llmPredictionRefreshTask`、打鍵ごとにキャンセル）後、`.composition(.awaitLLMPrediction(inputState:.composing))` を**非同期発火**。
3. サーバ `main.swift` がこの命令で `await session.manager.awaitPendingLLMRevision()`（進行中の `llmRevisionTask` の完了＝デバウンス＋推論を待つ）→ `requestPredictionCandidates()` が `llmPredictionBarCandidates()` 経由で LLM 候補を含めた snapshot を返す。
4. クライアント完了コールバックで、読みが変わっていなければ `currentConverterView` を更新し `refreshPredictionWindow()`。

結果、**入力を止めて ~1 秒後、予測バーに「履歴予測（即時）＋LLM 補正候補」が並ぶ**。確定は `commitsSurfaceDirectly`（Tab で surface 直挿入）。タイミングのズレ（固定遅延で当て推量）が無いのが await 方式の利点。

新規 XPC: `ConverterCompositionCommand.awaitLLMPrediction(inputState:)`（composition ハンドラを `async` 化）。

### 入力中から全候補を表示（**実装済み 2026-07-21**）

サジェストが存在するとき、入力中（composing）から候補ウィンドウに「サジェスト（前方一致履歴＋LLM）＋変換候補」を選択なしで全表示する（`getCurrentCandidateWindow(.composing)`）。下キーで先頭サジェストにハイライトが入り、そのまま矢印/マウス/Enter で選べる。内容が重複する小型の予測バーは、候補ウィンドウ表示中は出さない（クライアント `refreshPredictionWindow` で抑制）。LLM 補正が非同期に完了した場合、composing 中（選択なし）に限り snapshot を差し替えて入力中ウィンドウへ反映する。

### サジェスト選択（composing 中の下キー・**実装済み 2026-07-21**）

予測バーは表示のみで、バー内を矢印で選ぶ機構は無い（下キーは従来どおり候補一覧を開く）。
当初クライアント側でキーを介入してバー内選択を実装したが実機で機能せず撤去し、**サーバ統合方式**に再設計した:

- composing 中の下キー（`UserAction.navigation(.down)`）をサーバ `handleKeyEvent` で判別し、`SegmentsManager.requestSuggestionSelectionPreference()` を立てる（スペースと同じ `.enterCandidateSelectionMode` だがここで区別）。
- フラグON時の `rawCandidatesList` は「前方一致履歴サジェスト（`suggestionHistoryCandidates`、ruby は履歴側読み・composingCount は入力全体）＋LLM 補正候補＋辞書候補（dedup）」。**予測バーに見えている候補が一覧の先頭に並び、既存の矢印/マウス/Enter でそのまま選べる**。
- スペース変換（フラグOFF）は従来どおり「読み完全一致履歴＋辞書」で、前方一致サジェストが変換結果を乗っ取らない。
- フラグは新規入力・composition 終了・候補ウィンドウ非表示で解除。
- ブラウズ中（`selectionIndex != nil`）に LLM 結果が届いた場合は破棄し、開いている一覧を書き換えない。

### 変換候補ウィンドウ（スペース後）には LLM を入れない

当初 `rawCandidatesList` に「履歴（先頭）＋辞書＋LLM（末尾）」を差し込んでいたが、**撤去した（2026-07-21）**。理由: 変換候補ウィンドウは能動的にブラウズする画面で、非同期の LLM 候補が後から差し込まれると**選択中に候補が増減・変化して混乱する**（ユーザー報告「選択しようとすると別の選択肢が表示される」）。LLM は「変換前」の予測バー（B）専用にした。履歴候補は同期・安定なので候補ウィンドウにも先頭差し込みを維持。

同じ理由で、予測バーの非同期反映（`scheduleLLMPredictionRefreshIfNeeded` 完了時）も **`currentConverterView`（候補ウィンドウ状態）を上書きせず、予測バー表示（`displayPredictionCandidates`）だけを更新**する。

### バックエンドの整合（Foundation Models）

`AIClient.sendTextTransformRequest` の Foundation Models 経路は guided generation が `TextTransformResponse{result: String}`（単一文字列）に強制されるため、`LLMReviser` が期待する複数候補 `{"candidates":[...]}` を返せない。対策として **`FoundationModelsClient.sendRevisionRequest`（`@Generable RevisionResponse{candidates:[String]}`）** を追加し、`AIClientRevisionBackend.generate` の FM 分岐をそれ経由に変更、結果を `{"candidates":[...]}` 文字列へ整形して `parseCandidates` に渡す。OpenAI 分岐は従来どおり `sendTextTransformRequest`。

> `LLMReviser` 単体（サニタイズ・キャッシュ・パース・マージ・非同期 revise）はユニットテスト済み。実機での候補差し込みは Foundation Models AVAILABLE 環境で確認。

## 設定

- `Config.KiwiLLMReviserEnabled`（`BoolConfigItem`、デフォルト **false**）— プライバシーと性能を尊重し明示的に有効化。設定は「詳細設定」タブの Kiwi セクション。
- バックエンド選択・API キー・モデル名は既存の `AIBackendPreference` / `OpenAiApiKey` / `OpenAiModelName` / `OpenAiApiEndpoint` を再利用（「基本」タブの「いい感じ変換」と**共通**）。
- `AIBackendPreference` はデフォルト `.off`。LLM 補正トグルを ON にした際、バックエンドが `.off` かつ Foundation Models が利用可能なら**自動的に `.foundationModels` を選択**する（`ConfigWindow` の `onChange`）。これにより「トグルだけで効く」。

## 禁止事項（遵守）

- 入力内容を外部 API に送信しない（ローカル/オンデバイスが原則。OpenAI はユーザーが明示設定した場合のみ）。
- メインスレッドで LLM 推論を実行しない（`actor` + `async`）。
- センシティブ文脈をそのままプロンプトに含めない（サニタイズ必須）。
- キャンセルされた変換を履歴・学習に使わない。
- プライバシー設定を無視して強制 ON にしない（デフォルト OFF）。

## 性能目標

- 目標レイテンシ 300ms 以下（非同期なので辞書候補は即時表示）。
- 超過時はモデル・プロンプト長・キャッシュ戦略を見直す。

## テスト

`Core/Tests/CoreTests/KiwiLLMTests/LLMReviserTests.swift`（swift-testing、モックバックエンド使用）:
- サニタイズ（URL/メール/数字/パスの伏せ字化、短い数字は残す）
- `meaningfulLength`
- パース（オブジェクト形式 / 素の配列 / コードフェンス / 不正入力）
- dedupe / merge / maxResults
- revise の返り値、**キャッシュで2回目はバックエンド未呼び出し**、バックエンド無効/空読みで空返り

```bash
cd Core && swift test --filter KiwiLLM
```
