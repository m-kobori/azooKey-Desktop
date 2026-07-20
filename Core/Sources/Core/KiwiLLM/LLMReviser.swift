import Foundation

/// LLM が提案した補正候補。
public struct LLMRevisedCandidate: Sendable, Equatable {
    public var surface: String
    public init(surface: String) {
        self.surface = surface
    }
}

/// LLM 実行方式を抽象化するバックエンド。
///
/// 差し替え可能にすることで、
/// - 既存のオンデバイス AI（Foundation Models）/ OpenAI 経由（`AIClientRevisionBackend`）
/// - テスト用モック
/// を同じインターフェイスで扱える。プロンプト文字列を受け取り、モデルの生テキスト（JSON 想定）を返す。
public protocol LLMRevisionBackend: Sendable {
    /// バックエンドが現在利用可能か（モデル未ロード・APIキー未設定などで false）。
    var isAvailable: Bool { get }
    /// プロンプトを渡してモデルの生応答テキストを得る。
    func generate(prompt: String) async throws -> String
}

/// 確定前の変換候補を、読みと左文脈に基づいてローカル LLM で補正・並び替えする層。
///
/// 設計方針（詳細は `docs/llm-revision.md`）:
/// - **非同期**: IME 本体をブロックしない。辞書候補が先に表示され、LLM 候補は後から差し込む。
/// - **サニタイズ**: URL / メール / 数字列 / パスは LLM に渡す前に伏せ字化する。
/// - **キャッシュ**: `(sanitizedReading, sanitizedLeftContext, maxResults)` をキーに一定時間メモ化する。
/// - **プライバシー既定 OFF**: 呼び出し側で `Config.KiwiLLMReviserEnabled` を確認する。
public actor LLMReviser {
    private let backend: any LLMRevisionBackend
    private let cacheTTL: TimeInterval
    /// サニタイズ後の文脈がこの文字数未満（＝機密情報だけ）なら文脈を使わずに補正する。
    private let minimumMeaningfulContextLength: Int

    private struct CacheKey: Hashable {
        var reading: String
        var context: String
        var maxResults: Int
    }
    private struct CacheEntry {
        var candidates: [LLMRevisedCandidate]
        var storedAt: Date
    }
    private var cache: [CacheKey: CacheEntry] = [:]

    public init(
        backend: any LLMRevisionBackend,
        cacheTTL: TimeInterval = 600,
        minimumMeaningfulContextLength: Int = 2
    ) {
        self.backend = backend
        self.cacheTTL = cacheTTL
        self.minimumMeaningfulContextLength = minimumMeaningfulContextLength
    }

    public var isAvailable: Bool {
        self.backend.isAvailable
    }

    // MARK: - Revise

    /// 読みと左文脈から、既存候補を補正した候補列を返す。
    ///
    /// - Parameters:
    ///   - reading: 変換対象の読み（ひらがな）
    ///   - leftContext: 直前の文脈（未サニタイズで可。内部でサニタイズする）
    ///   - existingCandidates: 辞書ベースの既存候補（表記）
    ///   - maxResults: 返す最大件数
    /// - Returns: LLM が提案した候補（重複除去済み、最大 `maxResults` 件）。利用不可・入力不十分時は空。
    public func revise(
        reading: String,
        leftContext: String?,
        existingCandidates: [String],
        maxResults: Int
    ) async throws -> [LLMRevisedCandidate] {
        guard self.backend.isAvailable, !reading.isEmpty, maxResults > 0 else { return [] }

        let sanitizedContextRaw = Self.sanitizeContext(leftContext ?? "")
        // 機密情報を伏せた結果、意味のある文脈が残らない場合は文脈なしで補正する
        let sanitizedContext = Self.meaningfulLength(of: sanitizedContextRaw) >= self.minimumMeaningfulContextLength
            ? sanitizedContextRaw
            : ""

        let key = CacheKey(reading: reading, context: sanitizedContext, maxResults: maxResults)
        if let cached = self.validCacheEntry(for: key) {
            return cached
        }

        let prompt = Self.buildPrompt(
            reading: reading,
            sanitizedContext: sanitizedContext,
            existingCandidates: existingCandidates,
            maxResults: maxResults
        )
        let raw = try await self.backend.generate(prompt: prompt)
        try Task.checkCancellation()

        let parsed = Self.parseCandidates(from: raw)
        let deduped = Self.dedupe(parsed).prefix(maxResults).map(LLMRevisedCandidate.init(surface:))
        self.cache[key] = CacheEntry(candidates: deduped, storedAt: Date())
        return deduped
    }

    private func validCacheEntry(for key: CacheKey) -> [LLMRevisedCandidate]? {
        guard let entry = self.cache[key] else { return nil }
        if Date().timeIntervalSince(entry.storedAt) > self.cacheTTL {
            self.cache.removeValue(forKey: key)
            return nil
        }
        return entry.candidates
    }

    /// 期限切れのキャッシュを掃除する。
    public func purgeExpiredCache() {
        let now = Date()
        self.cache = self.cache.filter { now.timeIntervalSince($0.value.storedAt) <= self.cacheTTL }
    }

    // MARK: - Sanitize

    /// センシティブな文脈（URL / メール / 長い数字列 / ファイルパス）を伏せ字化する。
    public static func sanitizeContext(_ text: String) -> String {
        var result = text
        let rules: [(pattern: String, replacement: String)] = [
            (#"https?://\S+"#, "[URL]"),
            (#"[\w.+-]+@[\w-]+\.[\w.-]+"#, "[EMAIL]"),
            (#"(?:/[\w.\-]+){2,}/?"#, "[PATH]"),
            (#"\d{4,}"#, "[NUMBER]")
        ]
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: .regularExpression
            )
        }
        return result
    }

    /// 伏せ字プレースホルダを除いた「意味のある」文字数。
    static func meaningfulLength(of sanitized: String) -> Int {
        let placeholders = ["[URL]", "[EMAIL]", "[PATH]", "[NUMBER]"]
        var stripped = sanitized
        for placeholder in placeholders {
            stripped = stripped.replacingOccurrences(of: placeholder, with: "")
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    // MARK: - Prompt

    static func buildPrompt(
        reading: String,
        sanitizedContext: String,
        existingCandidates: [String],
        maxResults: Int
    ) -> String {
        let candidatesLine = existingCandidates.isEmpty ? "(なし)" : existingCandidates.joined(separator: ", ")
        let contextLine = sanitizedContext.isEmpty ? "(なし)" : sanitizedContext
        return """
        あなたは日本語入力の変換候補を補正するアシスタントです。
        前文と読みから、最も自然な表記を最大\(maxResults)個提案してください。
        - 出力は必ず JSON オブジェクト1つだけ。前後に説明文やコードフェンスを付けない。
        - 形式: {"candidates": ["表記1", "表記2"]}
        - 既存候補にない表記を提案してもよい。英語が混じる場合はそのまま尊重する。

        前文: \(contextLine)
        読み: \(reading)
        既存候補: \(candidatesLine)
        """
    }

    // MARK: - Parse

    /// モデルの生テキストから候補配列を取り出す。
    /// `{"candidates": [...]}`、素の JSON 配列、コードフェンス付きのいずれにも対応する。
    static func parseCandidates(from raw: String) -> [String] {
        let cleaned = stripCodeFence(raw)

        // 1) {"candidates": [...]} 形式
        if let range = cleaned.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
           let data = String(cleaned[range]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = object["candidates"] as? [String] {
            return candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        // 2) 素の JSON 配列 ["...", "..."]
        if let range = cleaned.range(of: #"\[[\s\S]*\]"#, options: .regularExpression),
           let data = String(cleaned[range]).data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        return []
    }

    private static func stripCodeFence(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            // ```json ... ``` を剥がす
            result = result.replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            if let fenceRange = result.range(of: "```", options: .backwards) {
                result = String(result[result.startIndex ..< fenceRange.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where !item.isEmpty && seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    // MARK: - Merge

    /// 辞書候補と LLM 候補をマージする。
    /// 辞書候補を先に置き、LLM 由来の新規表記のみを後段に追加する（重複は除去）。
    public static func merge(existing: [String], revised: [LLMRevisedCandidate], maxResults: Int) -> [String] {
        var seen = Set(existing)
        var result = existing
        for candidate in revised where seen.insert(candidate.surface).inserted {
            result.append(candidate.surface)
        }
        if maxResults > 0 {
            return Array(result.prefix(maxResults))
        }
        return result
    }
}
