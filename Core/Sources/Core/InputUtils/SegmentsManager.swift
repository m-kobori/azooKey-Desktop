import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class SegmentsManager {
    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        public init(useZenzai: Bool, resourcesDirectoryURL: URL? = nil) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
        }

        var useZenzai: Bool = true
        var resourcesDirectoryURL: URL?
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    private var kanaKanjiConverter: KanaKanjiConverter
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        // Kiwi: 英語モードの composing ではライブ変換を無効にする（ASCII をそのまま表示する）。
        Config.LiveConversion().value && self.currentInputLanguage == .japanese
    }

    /// Kiwi: 現在の入力言語。キーイベントごとにサーバが設定する（ライブ変換抑制・英語履歴記録用）。
    private var currentInputLanguage: InputLanguage = .japanese

    /// Kiwi: サーバのキーイベント処理から現在の入力言語を伝える。
    public func setCurrentInputLanguage(_ language: InputLanguage) {
        self.currentInputLanguage = language
    }

    /// Kiwi: クライアントがパスワードマネージャー等のセンシティブなアプリか。
    /// true の間は履歴記録と LLM 送出を停止する（変換・サジェスト表示は通常どおり）。
    private var isSensitiveClient: Bool = false

    /// Kiwi: サーバのキーイベント処理からセンシティブクライアント判定を伝える。
    public func setSensitiveClient(_ sensitive: Bool) {
        self.isSensitiveClient = sensitive
    }

    /// Kiwi: クライアントがターミナルアプリか。true の間、英語 composing で
    /// シェル履歴コマンド・パス補完をサジェストし、英語確定の履歴記録は行わない。
    private var isTerminalClient: Bool = false

    /// Kiwi: シェル履歴（~/.zsh_history 等）由来のコマンドサジェスト提供。
    private let shellHistoryProvider = ShellHistoryProvider()

    /// Kiwi: ターミナル向けサジェスト（コマンド・パス）の Candidate 列。
    /// `updateRawCandidate` で再計算し、`suggestionLeadCandidates` の先頭へ差し込む。
    private var terminalSuggestionCandidates: [Candidate] = []

    /// Kiwi: サーバのキーイベント処理からターミナルクライアント判定を伝える。
    public func setTerminalClient(_ terminal: Bool) {
        self.isTerminalClient = terminal
    }

    /// Kiwi: ターミナル向けサジェスト（シェル履歴コマンド → パス補完）を再計算する。
    /// 英語 composing のみ対象（コマンドは ASCII。日本語入力は通常動作）。
    @MainActor private func updateTerminalSuggestionCandidates() {
        guard Config.KiwiTerminalSuggestionEnabled().value,
              self.isTerminalClient,
              self.currentInputLanguage == .english else {
            self.terminalSuggestionCandidates = []
            return
        }
        let target = self.convertTarget
        guard target.count >= 2 else {
            self.terminalSuggestionCandidates = []
            return
        }
        let inputCount = self.composingText.input.count
        let commands = self.shellHistoryProvider.suggest(prefix: target, limit: 3)
        let paths = PathCompleter.suggest(composing: target, limit: 3)
        var seen = Set<String>()
        self.terminalSuggestionCandidates = (commands + paths)
            .filter { !$0.isEmpty && $0 != target && seen.insert($0).inserted }
            .map { suggestion in
                Candidate(
                    text: suggestion,
                    value: 0,
                    composingCount: .inputCount(inputCount),
                    lastMid: MIDData.一般.mid,
                    data: [DicdataElement(
                        word: suggestion,
                        ruby: suggestion.toKatakana(),
                        cid: CIDData.固有名詞.cid,
                        mid: MIDData.一般.mid,
                        value: 0
                    )]
                )
            }
    }

    /// Kiwi: 英語モードで確定したテキストを履歴に記録する（読み＝表記）。
    /// 次回、先頭数文字のプレフィックス一致でサジェストされる。
    public func recordEnglishCommit(_ text: String, leftSideContext: String) {
        // センシティブなクライアント（パスワードマネージャー等）では記録しない。
        guard !self.isSensitiveClient else { return }
        // ターミナルでは記録しない（シェルコマンドで通常アプリのサジェストを汚さない。
        // コマンドのサジェストはシェル履歴を直接ソースにする）。
        guard !self.isTerminalClient else { return }
        guard Config.KiwiHistoryEnabled().value, let historyManager = self.historyManager else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        Task.detached(priority: .utility) {
            historyManager.record(reading: trimmed, surface: trimmed, leftContext: leftSideContext)
        }
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?

    /// Kiwi: 確定履歴の永続化（SQLite）。設定 OFF・コンテナ未取得・初期化失敗時は nil。
    private lazy var historyManager: HistoryManager? = self.makeHistoryManager()

    /// Kiwi: 現在の読みに一致する確定履歴から作った候補。`updateRawCandidate` で再計算し、
    /// `rawCandidatesList` の先頭へ差し込む（＝過去の確定を最優先で提示する）。
    private var historyPredictionCandidates: [Candidate] = []

    /// Kiwi: 前方一致を含む履歴サジェスト候補（予測バーに出るものと同源）。
    /// 下キーで開くサジェスト選択（`preferSuggestionSelection`）時に一覧の先頭へ差し込む。
    private var suggestionHistoryCandidates: [Candidate] = []

    /// Kiwi: 次に開く候補一覧を「サジェスト優先」にするか。
    /// composing 中に下キーで候補一覧を開いたとき true（サーバのキー処理から設定）。
    /// 新しい入力・composition 終了・候補ウィンドウ非表示で解除。
    private var preferSuggestionSelection = false

    /// Kiwi: composing 中の下キーで呼ばれ、次の候補一覧をサジェスト優先にする。
    @MainActor public func requestSuggestionSelectionPreference() {
        self.preferSuggestionSelection = true
    }

    /// Kiwi: LLM 補正（NT-831）。設定 OFF・バックエンド未選択時は nil。
    private lazy var llmReviser: LLMReviser? = self.makeLLMReviser()
    /// 進行中の LLM 補正タスク（デバウンス兼キャンセル用）。打鍵ごとに張り替える。
    @MainActor private var llmRevisionTask: Task<Void, Never>?
    /// LLM 補正のデバウンス遅延（ミリ秒）。連続入力中の無駄な推論を抑止する。
    private static let llmRevisionDebounceMilliseconds = 150
    /// Kiwi: LLM が補正した候補（`rawCandidatesList` の末尾へ dedup 追加する）。
    /// XPC はプル型でサーバ発プッシュが無いため、非同期の結果は次のスナップショット
    /// （候補ブラウズ等の次キーイベント）で反映される。
    private var llmRevisedCandidates: [Candidate] = []
    /// `llmRevisedCandidates` が対象としている読み。読みが変わったら破棄する。
    private var llmRevisedTarget: String = ""

    private func makeLLMReviser() -> LLMReviser? {
        guard Config.KiwiLLMReviserEnabled().value else { return nil }
        // Foundation Models（オンデバイス）既定。OpenAI 選択時のキーはアプリ側管理のため
        // Core からは空キーで生成する（OpenAI 利用は将来、呼び出し側から注入する）。
        return LLMReviser(backend: AIClientRevisionBackend())
    }

    private func makeHistoryManager() -> HistoryManager? {
        guard Config.KiwiHistoryEnabled().value else { return nil }
        do {
            let manager: HistoryManager
            if let containerURL = self.containerURL {
                manager = try HistoryManager(containerURL: containerURL)
            } else {
                // App Group コンテナが無い環境（ローカルのアドホック署名ビルド等、App Group 未使用時）は、
                // アプリのサポートディレクトリ配下に履歴 DB を作成する。
                // applicationDirectoryURL は .../azooKey/memory を指すため、その親（.../azooKey）に KiwiHistory を置く。
                let baseDirectory = self.applicationDirectoryURL.deletingLastPathComponent()
                let databaseURL = baseDirectory
                    .appendingPathComponent("KiwiHistory", isDirectory: true)
                    .appendingPathComponent("history.sqlite", isDirectory: false)
                manager = try HistoryManager(databaseURL: databaseURL)
            }
            // コールドスタート回避: シード未投入なら定型句を初期投入する（実利用の学習が貯まれば上書きされる）。
            manager.seedIfNeeded(HistorySeedData.entries)
            // 1日1回の頻度減衰: 最近使わない語の優先度を徐々に下げ、不要行を削除する。
            // 機密らしき既存エントリ（過去に保存されたパスワード等）の遡及削除もあわせて行う。
            // メインスレッドをブロックしないようバックグラウンドで実行する。
            Task.detached(priority: .utility) {
                manager.decayDailyIfNeeded()
                manager.deleteSensitiveEntries()
            }
            return manager
        } catch {
            self.appendDebugMessage("❌ KiwiHistory: 初期化に失敗しました: \(error)")
            return nil
        }
    }

    /// Kiwi: 確定した候補を履歴に記録する。DB 書き込みでメインスレッドをブロックしないよう
    /// 値をコピーしてバックグラウンドで実行する。
    private func recordHistoryIfNeeded(_ candidate: Candidate, leftSideContext: String) {
        // センシティブなクライアント（パスワードマネージャー等）では記録しない。
        guard !self.isSensitiveClient else { return }
        guard Config.KiwiHistoryEnabled().value, let historyManager = self.historyManager else { return }
        let reading = self.candidateReading(candidate).toHiragana()
        let surface = candidate.text
        guard !reading.isEmpty, !surface.isEmpty else { return }
        Task.detached(priority: .utility) {
            historyManager.record(reading: reading, surface: surface, leftContext: leftSideContext)
        }
    }

    /// Kiwi: 現在の読み（`convertTarget`）に一致する確定履歴を候補として用意する。
    ///
    /// - `historyPredictionCandidates`: 読み完全一致のみ。スペース変換の一覧の先頭に差し込む
    ///   （同じ読みの確定実績を最優先で出す。変換結果を乗っ取らない）。
    /// - `suggestionHistoryCandidates`: 前方一致を含む全予測。下キーで開く「サジェスト選択」
    ///   一覧の先頭に差し込む（予測バーに見えているものをそのまま矢印/マウスで選べる）。
    ///   composingCount は入力全体を覆うため、確定すると読み全体が surface に置き換わる。
    @MainActor private func updateHistoryPredictionCandidates(leftSideContext: String?) {
        guard Config.KiwiHistoryEnabled().value, let historyManager = self.historyManager else {
            self.historyPredictionCandidates = []
            self.suggestionHistoryCandidates = []
            return
        }
        let reading = self.convertTarget
        // 1 文字だと候補が氾濫するため 2 文字以上に限定。
        guard reading.count >= 2 else {
            self.historyPredictionCandidates = []
            self.suggestionHistoryCandidates = []
            return
        }
        let inputCount = self.composingText.input.count
        let makeCandidate: (HistoryCandidate) -> Candidate = { prediction in
            Candidate(
                text: prediction.surface,
                value: 0,
                composingCount: .inputCount(inputCount),
                lastMid: MIDData.一般.mid,
                data: [DicdataElement(
                    word: prediction.surface,
                    // ruby は履歴側の読み（前方一致では現在の入力より長い）。学習・履歴記録の整合のため。
                    ruby: prediction.reading.toKatakana(),
                    cid: CIDData.固有名詞.cid,
                    mid: MIDData.一般.mid,
                    value: 0
                )]
            )
        }
        let predictions = historyManager
            .predict(reading: reading, leftContext: leftSideContext, limit: 5)
            .filter { !$0.surface.isEmpty }
        self.historyPredictionCandidates = predictions.filter { $0.reading == reading }.map(makeCandidate)
        self.suggestionHistoryCandidates = predictions.map(makeCandidate)
    }

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
        /// Kiwi: true の場合、確定時に読み（appendText）を追記せず `displayText` を surface として
        /// そのまま確定する（＝履歴予測。スペースを押す前に学習語を確定できる）。
        public var commitsSurfaceDirectly: Bool = false
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    private func candidateReading(_ candidate: Candidate) -> String {
        candidate.data.map(\.ruby).joined()
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.zenzaiPersonalizationLevel.alpha
        // オフなので。
        if alpha == 0 {
            return nil
        }
        guard let containerURL else {
            self.appendDebugMessage("❌ Failed to get container URL.")
            return nil
        }

        let base = self.resourcesDirectoryURL.appendingPathComponent("lm", isDirectory: false).path
        let personal = containerURL.appendingPathComponent("Library/Application Support/p13n_v1").path + "/lm"
        // check personal lm existence
        guard [
            FileManager.default.fileExists(atPath: personal + "_c_abc.marisa"),
            FileManager.default.fileExists(atPath: personal + "_r_xbx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_abx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_xbc.marisa")
        ].allSatisfy(\.self) else {
            self.appendDebugMessage("❌ Seems like there is missing marisa file for prefix \(personal)")
            return nil
        }

        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case other
    }

    private enum ContextLength {
        static let conversion = 30
    }

    public func appendDebugMessage(_ string: String) {
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool
    ) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false),
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v3(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    enableAlignmentSeparator: true,
                    )
            )
        )
    }

    private var resourcesDirectoryURL: URL {
        if let resourcesDirectoryURL = self.context.resourcesDirectoryURL {
            return resourcesDirectoryURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "azooKey on macOS (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "azooKey on macOS (\(commit.prefix(7)))")
        } else {
            .init(versionString: "azooKey on macOS (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode
    ) -> ConvertRequestOptions {
        .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: self.zenzaiMode(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates
            ),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var azooKeyMemoryDir: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func deactivate() {
        self.kanaKanjiConverter.stopComposition()
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.rawCandidates = nil
        self.historyPredictionCandidates = []
        self.suggestionHistoryCandidates = []
        self.terminalSuggestionCandidates = []
        self.preferSuggestionSelection = false
        self.clearLLMRevision()
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.rawCandidates = nil
        self.historyPredictionCandidates = []
        self.suggestionHistoryCandidates = []
        self.terminalSuggestionCandidates = []
        self.preferSuggestionSelection = false
        self.clearLLMRevision()
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // すでに末尾がcompositionSeparatorの場合は何もしない
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
        }
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.kanaKanjiConverter.forgetMemory(selectedCandidate)
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        guard let base = self.baseRawCandidatesList else {
            return nil
        }
        // 変換範囲を手動編集した場合は読みが部分と一致しないため、履歴は差し込まない。
        guard !self.didExperienceSegmentEdition else {
            return base
        }
        // Kiwi: 下キーで開いたサジェスト選択では、サジェスト（前方一致履歴＋LLM）を
        // 一覧の先頭に差し込む。入力中に見えている「会議の議題」等をそのまま矢印/マウスで選べる。
        // ※ 選択中の一覧が変化しないよう、LLM は結果到着時に選択中なら破棄する（scheduleLLMRevision 側）。
        if self.preferSuggestionSelection {
            let suggestions = self.suggestionLeadCandidates
            if !suggestions.isEmpty {
                let seen = Set(suggestions.map(\.text))
                return suggestions + base.filter { !seen.contains($0.text) }
            }
        }
        // スペース変換の一覧: 読み完全一致の履歴のみ先頭に（変換結果を乗っ取らない）。
        guard !self.historyPredictionCandidates.isEmpty else {
            return base
        }
        let historySurfaces = Set(self.historyPredictionCandidates.map(\.text))
        let dedupedBase = base.filter { !historySurfaces.contains($0.text) }
        return self.historyPredictionCandidates + dedupedBase
    }

    /// Kiwi: 辞書ベースの読み予測（predictionResults）をサジェスト用候補に変換する。
    ///
    /// 予測候補は読みが現在の入力より長いため、そのまま submit すると composingCount が
    /// 入力と食い違う恐れがある。履歴サジェストと同じく「composingCount = 入力全体」の
    /// Candidate に包み直し、確定時に読み全体が surface へ置き換わるようにする。
    private var dictionaryPredictionSuggestionCandidates: [Candidate] {
        guard Config.KiwiDictionaryPredictionEnabled().value, let rawCandidates else { return [] }
        let inputCount = self.composingText.input.count
        return rawCandidates.predictionResults.prefix(5).map { candidate in
            Candidate(
                text: candidate.text,
                value: candidate.value,
                composingCount: .inputCount(inputCount),
                lastMid: candidate.lastMid,
                data: candidate.data
            )
        }
    }

    /// Kiwi: サジェスト（ターミナル＋前方一致履歴＋辞書予測＋準備済み LLM 補正）の結合リスト（surface で dedup）。
    /// 入力中の候補ウィンドウ表示と、下キーのサジェスト選択の両方で同じ内容を使う。
    /// 順序: ターミナル（コマンド/パス）→ 履歴（個人の実績）→ 辞書予測（一般語彙）→ LLM 補正。
    private var suggestionLeadCandidates: [Candidate] {
        let llmCandidates = self.llmRevisedTarget == self.convertTarget ? self.llmRevisedCandidates : []
        var seen = Set<String>()
        return (self.terminalSuggestionCandidates + self.suggestionHistoryCandidates + self.dictionaryPredictionSuggestionCandidates + llmCandidates)
            .filter { seen.insert($0.text).inserted }
    }

    private var baseRawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: maxCount).map {
            var last = $0.split(separator: "\n", omittingEmptySubsequences: false).last ?? $0[...]
            // 前方の空白を削除する
            while last.first?.isWhitespace ?? false {
                last = last.dropFirst()
            }
            return String(last)
        }
    }

    public func getCleanRightSideContext(maxCount: Int) -> String? {
        self.delegate?.getRightSideContext(maxCount: maxCount).map {
            var first = $0.split(separator: "\n", omittingEmptySubsequences: false).first ?? $0[...]
            // 後方の空白を削除する
            while first.last?.isWhitespace ?? false {
                first = first.dropLast()
            }
            return String(first)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil
    ) {
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        // Kiwi: 入力が変わったらサジェスト優先モードは解除（次の下キーで再度有効化される）。
        self.preferSuggestionSelection = false
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.historyPredictionCandidates = []
            self.suggestionHistoryCandidates = []
            self.terminalSuggestionCandidates = []
            self.clearLLMRevision()
            self.kanaKanjiConverter.stopComposition()
            return
        }
        /// 日付・時刻変換を事前に入れておく
        let dynamicShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // 月
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // 年
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // 時刻
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

        self.kanaKanjiConverter.importDynamicUserDictionary([], shortcuts: dynamicShortcuts)

        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let rightSideContext = forcedRightSideContext ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion)
        let result = self.kanaKanjiConverter.requestCandidates(
            self.composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates,
                // Kiwi: 辞書ベースの読み予測（「あり」→「ありがとう」等の補完）を正式に有効化。
                // 開発中フラグ（DebugPredictiveTyping）とは独立に、KiwiDictionaryPredictionEnabled で制御する。
                requireJapanesePrediction: (Config.DebugPredictiveTyping().value || Config.KiwiDictionaryPredictionEnabled().value) ? .manualMix : .disabled,
                requireEnglishPrediction: (Config.DebugPredictiveTyping().value || Config.KiwiDictionaryPredictionEnabled().value) ? .manualMix : .disabled
            )
        )
        self.rawCandidates = result
        self.updateHistoryPredictionCandidates(leftSideContext: leftSideContext)
        self.updateTerminalSuggestionCandidates()
        self.scheduleLLMRevision(leftSideContext: leftSideContext)
    }

    /// Kiwi: LLM 補正（NT-831）をデバウンス起動する。
    ///
    /// メインスレッドをブロックしないよう、辞書候補を先に確定表示したうえで、
    /// バックグラウンド（actor）で `LLMReviser.revise` を実行する。結果が揃ったら
    /// `llmRevisedCandidates` に格納し、次のスナップショットで候補列へ反映する。
    /// - 設定 OFF・読みが空・読みが変化した場合はキャンセル/破棄する。
    /// - キャンセル確定などの誤変換学習防止は履歴側と同様、確定処理側で行う（ここは表示のみ）。
    /// Kiwi: LLM 補正の状態を破棄し、進行中のデバウンス/推論をキャンセルする。
    @MainActor private func clearLLMRevision() {
        self.llmRevisionTask?.cancel()
        self.llmRevisionTask = nil
        self.llmRevisedCandidates = []
        self.llmRevisedTarget = ""
    }

    /// Kiwi: 進行中の LLM 補正タスク（デバウンス＋推論）の完了を待つ。
    /// Client の `awaitLLMPrediction` 命令から呼ばれ、完了後の snapshot に LLM 候補を載せる。
    @MainActor public func awaitPendingLLMRevision() async {
        await self.llmRevisionTask?.value
    }

    @MainActor private func scheduleLLMRevision(leftSideContext: String?) {
        // センシティブなクライアント（パスワードマネージャー等）では入力・文脈を LLM に渡さない。
        guard !self.isSensitiveClient else {
            self.clearLLMRevision()
            return
        }
        guard Config.KiwiLLMReviserEnabled().value, let llmReviser = self.llmReviser else {
            self.llmRevisedCandidates = []
            self.llmRevisedTarget = ""
            return
        }
        let target = self.convertTarget
        guard target.count >= 2 else {
            self.llmRevisedCandidates = []
            self.llmRevisedTarget = ""
            return
        }
        // 読みが変わったら前回の補正結果は無効。
        if target != self.llmRevisedTarget {
            self.llmRevisedCandidates = []
        }
        let inputCount = self.composingText.input.count
        let ruby = target.toKatakana()
        // 既存の辞書候補（表記）を LLM に渡してリランク・補正の材料にする。
        let existing = Array((self.baseRawCandidatesList ?? []).prefix(8).map(\.text))
        let context = leftSideContext

        // 打鍵ごとに呼ばれるため、MainActor 隔離タスクを張り替えてデバウンスする
        // （前回の待機/推論はキャンセル）。closure は MainActor 隔離なので self を安全に触れる。
        self.llmRevisionTask?.cancel()
        self.llmRevisionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Self.llmRevisionDebounceMilliseconds))
            } catch {
                return // デバウンス中にキャンセルされた
            }
            let revised: [LLMRevisedCandidate]
            do {
                revised = try await llmReviser.revise(
                    reading: target,
                    leftContext: context,
                    existingCandidates: existing,
                    maxResults: 3
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // 実行中に読みが変わっていたら破棄（古い結果で上書きしない）。
            guard self.convertTarget == target else { return }
            // 候補一覧をブラウズ中（選択中）は反映しない。開いている一覧が途中で変化して
            // 選択が飛ぶのを防ぐ（ユーザー報告「選択しようとすると別の候補が出る」の再発防止）。
            guard self.selectionIndex == nil else { return }
            let existingSurfaces = Set(existing)
            self.llmRevisedCandidates = revised
                .map(\.surface)
                .filter { !$0.isEmpty && !existingSurfaces.contains($0) }
                .map { surface in
                    Candidate(
                        text: surface,
                        value: 0,
                        composingCount: .inputCount(inputCount),
                        lastMid: MIDData.一般.mid,
                        data: [DicdataElement(
                            word: surface,
                            ruby: ruby,
                            cid: CIDData.固有名詞.cid,
                            mid: MIDData.一般.mid,
                            value: 0
                        )]
                    )
                }
            self.llmRevisedTarget = target
        }
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        self.kanaKanjiConverter.setCompletedData(candidate)
        self.kanaKanjiConverter.updateLearningData(candidate)
        // Kiwi: 確定した「読み→表記」を履歴に保存する（予測変換の基盤）。
        self.recordHistoryIfNeeded(candidate, leftSideContext: leftSideContext)
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
        if !visible {
            // Kiwi: 候補ウィンドウを閉じたらサジェスト優先モードも解除する。
            self.preferSuggestionSelection = false
        }
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            // Kiwi: サジェストがあれば入力中から候補ウィンドウに全候補（サジェスト＋変換候補）を
            // 表示する（「最初から全部出す」）。選択は無し（下キーで先頭サジェストに入る）。
            let suggestions = self.suggestionLeadCandidates
            if !suggestions.isEmpty, !self.didExperienceSegmentEdition {
                let base = self.baseRawCandidatesList ?? []
                let seen = Set(suggestions.map(\.text))
                return .composing(suggestions + base.filter { !seen.contains($0.text) }, selectionIndex: nil)
            }
            if !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public init(text: [Element], selectionRange: NSRange) {
            self.text = text
            self.selectionRange = selectionRange
        }

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        if let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "")
        }
        self.stopComposition()
        return text
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugTypoCorrection().value else {
            return []
        }
        guard let backspaceAdjustedPredictionCandidate else {
            return []
        }
        return [backspaceAdjustedPredictionCandidate]
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return []
        }

        var results: [PredictionCandidate] = []

        // Kiwi: 確定履歴からの予測。スペースで変換する前に、学習した語を予測バーに提示する。
        // `DebugPredictiveTyping` とは独立に、`KiwiHistoryEnabled` のみで有効化される。
        results.append(contentsOf: self.historyPredictionBarCandidates(target: target))

        // Kiwi: LLM 補正（NT-831）。非同期で用意済みの補正候補を、履歴の後に予測バーへ併記する。
        // 反映は Client の `awaitLLMPrediction` 命令（推論完了を待って snapshot 再取得）による。
        results.append(contentsOf: self.llmPredictionBarCandidates(target: target))

        // 既存: 読み補完予測（開発中機能）。読みが今より長い語を補完サジェストする。
        if Config.DebugPredictiveTyping().value, let rawCandidates {
            for candidate in rawCandidates.predictionResults {
                let reading = candidateReading(candidate)
                guard !reading.isEmpty else {
                    continue
                }
                if let predictionCandidate = Self.makePredictionCandidate(
                    currentTarget: target,
                    candidateReading: reading,
                    displayText: candidate.text
                ) {
                    results.append(predictionCandidate)
                    break
                }
            }
        }

        // surface の重複を除去（履歴予測を優先）。
        var seen = Set<String>()
        return results.filter { seen.insert($0.displayText).inserted }
    }

    /// Kiwi: 予測バー用に、現在の読みと完全一致する確定履歴を予測候補へ変換する。
    /// 確定時は `commitsSurfaceDirectly` により surface を直接確定する。
    private func historyPredictionBarCandidates(target: String) -> [PredictionCandidate] {
        guard Config.KiwiHistoryEnabled().value, let historyManager, target.count >= 2 else {
            return []
        }
        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        // 前方一致（predict は reading LIKE 'target%'）。数文字打てば長い定型句・学習語が出る。
        // 確定は surface 直挿入（commitsSurfaceDirectly）なので読み長のズレは問題にならない。
        return historyManager
            .predict(reading: target, leftContext: leftSideContext, limit: 5)
            .filter { !$0.surface.isEmpty }
            .map { PredictionCandidate(displayText: $0.surface, appendText: "", deleteCount: 0, commitsSurfaceDirectly: true) }
    }

    /// Kiwi: 予測バー用に、非同期で用意済みの LLM 補正候補を予測候補へ変換する。
    /// 読みが現在の対象と一致するときのみ有効。確定は surface 直挿入（`commitsSurfaceDirectly`）。
    private func llmPredictionBarCandidates(target: String) -> [PredictionCandidate] {
        guard Config.KiwiLLMReviserEnabled().value,
              self.llmRevisedTarget == target,
              !self.llmRevisedCandidates.isEmpty else {
            return []
        }
        return self.llmRevisedCandidates
            .map(\.text)
            .filter { !$0.isEmpty }
            .map { PredictionCandidate(displayText: $0, appendText: "", deleteCount: 0, commitsSurfaceDirectly: true) }
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidateReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidateReading.toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: displayText, appendText: appendText, deleteCount: deleteCount)
    }

    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        let typoCandidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: targetComposingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            ),
            inputStyle: inputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                beamSize: 16,
                topK: 32,
                nBest: 3
            )
        )

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.kanaKanjiConverter.requestCandidates(
            composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete {
                // 削除のあとは常にひらがなを示す
                self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.rawCandidates?.mainResults.first,
               self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: afterComposingText.convertTarget, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    func getRightSideContext(maxCount: Int) -> String?
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
