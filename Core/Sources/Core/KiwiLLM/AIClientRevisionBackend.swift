import Foundation

public enum LLMReviserError: LocalizedError {
    case backendUnavailable
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "LLM 補正のバックエンドが無効です（設定で有効化してください）。"
        case .missingAPIKey:
            return "OpenAI API キーが設定されていません。"
        }
    }
}

/// 既存の AI 基盤（`AIClient` → Foundation Models / OpenAI）を再利用する `LLMRevisionBackend` 実装。
///
/// - Note: `AIClient` はプロンプト文字列を受け取り、モデル応答（JSON 文字列）を返す。
///   新たな推論エンジンを追加せず、リポジトリに既にあるオンデバイス AI（Foundation Models）を優先利用する。
/// - Important: ローカル gguf（Zenzai）は自由文生成 API として公開されていないため、
///   本アダプタでは利用しない。将来 Zenzai / llama.cpp を自由文生成に使う場合は、
///   同じ `LLMRevisionBackend` を実装した別バックエンドを差し込めばよい。
public struct AIClientRevisionBackend: LLMRevisionBackend {
    /// OpenAI 用の API キー。
    ///
    /// - Note: `Config.OpenAiApiKey` は **アプリ（azooKeyMac）ターゲット側**（Keychain 管理）で定義されており、
    ///   `Core` からは参照できない。そのため OpenAI を使う場合は呼び出し側から注入する。
    ///   Foundation Models（オンデバイス）を使う既定パスではキーは不要。
    private let apiKey: String

    public init(apiKey: String = "") {
        self.apiKey = apiKey
    }

    public var isAvailable: Bool {
        switch Config.AIBackendPreference().value {
        case .off:
            return false
        case .foundationModels:
            return true
        case .openAI:
            return !self.apiKey.isEmpty
        }
    }

    public func generate(prompt: String) async throws -> String {
        switch Config.AIBackendPreference().value {
        case .off:
            throw LLMReviserError.backendUnavailable
        case .foundationModels:
            // Foundation Models は guided generation で複数候補を直接得る。
            // sendTextTransformRequest は単一 result に強制されるため、補正では専用パスを使い、
            // LLMReviser.parseCandidates が解釈できる {"candidates":[...]} 文字列へ整形して返す。
            let candidates = try await FoundationModelsClientCompat.sendRevisionRequest(prompt)
            let object: [String: [String]] = ["candidates": candidates]
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8) ?? #"{"candidates":[]}"#
        case .openAI:
            if self.apiKey.isEmpty {
                throw LLMReviserError.missingAPIKey
            }
            return try await AIClient.sendTextTransformRequest(
                prompt,
                backend: .openAI,
                modelName: Config.OpenAiModelName().value,
                apiKey: self.apiKey,
                apiEndpoint: Config.OpenAiApiEndpoint().value
            )
        }
    }
}
