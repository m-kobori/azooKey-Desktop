import Foundation

protocol BoolConfigItem: ConfigItem<Bool> {
    static var `default`: Bool { get }
}

extension BoolConfigItem {
    public var value: Bool {
        get {
            if let value = Config.object(forKey: Self.key) {
                value as? Bool ?? Self.default
            } else {
                Self.default
            }
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    /// デバッグウィンドウにd/Dで遷移する設定
    public struct DebugWindow: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.debug.enableDebugWindow"
    }
    /// 予測入力のデバッグ機能を有効化する設定
    public struct DebugPredictiveTyping: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.debug.predictiveTyping"
    }
    /// 入力訂正のデバッグ機能を有効化する設定
    public struct DebugTypoCorrection: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.debug.typoCorrection"
    }
    /// ライブ変換を有効化する設定
    public struct LiveConversion: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.enableLiveConversion"
    }
    /// 円マークの代わりにバックスラッシュを入力する設定
    public struct TypeBackSlash: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.typeBackSlash"
    }
    /// 「　」の代わりに「 」を入力する設定
    public struct TypeHalfSpace: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.typeHalfSpace"
    }
    /// Optionキー押下時に直接全角英数を入力する設定
    public struct OptionDirectFullWidthInput: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.optionDirectFullWidthInput"
    }
    /// AI変換時にコンテキストを含めるかどうか
    public struct IncludeContextInAITransform: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.includeContextInAITransform"
    }
    /// Kiwi: 確定した変換を SQLite 履歴に保存する設定（予測変換の基盤）
    public struct KiwiHistoryEnabled: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.kiwi.historyEnabled"
    }
    /// Kiwi: 変換候補をローカル LLM で補正・並び替えする設定（デフォルト OFF）
    public struct KiwiLLMReviserEnabled: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.kiwi.llmReviserEnabled"
    }
    /// Kiwi: 英語モードでも composing（下線入力）してサジェストを出す設定。
    /// OFF にすると従来どおり英語は直接挿入（サジェストなし）になる。
    public struct KiwiEnglishSuggestionEnabled: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.kiwi.englishSuggestionEnabled"
    }
    /// Kiwi: 辞書ベースの読み予測（「あり」→「ありがとう」等の補完）をサジェストに含める設定。
    /// スマホ IME の予測変換に相当する層。開発中フラグ DebugPredictiveTyping とは独立。
    public struct KiwiDictionaryPredictionEnabled: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.kiwi.dictionaryPredictionEnabled"
    }
}
