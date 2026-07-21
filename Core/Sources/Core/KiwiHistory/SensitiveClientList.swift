import Foundation

/// Kiwi: 履歴記録・LLM 送出を停止する「センシティブなクライアントアプリ」の一覧。
///
/// パスワードマネージャー等では、入力内容（マスターパスワード・登録中の秘密情報）を
/// 学習・記録してはならない。クライアント（azooKeyMac）が前面アプリの bundle identifier を
/// この一覧と照合し、`ConverterKeyEventRequest.isSensitiveClient` として Server へ伝える。
/// 変換・サジェスト表示は通常どおり動作し、保存だけが止まる。
public enum SensitiveClientList {
    /// bundle identifier の前方一致で判定する（バージョン違いの ID 差異を吸収）。
    public static let prefixes: [String] = [
        // 1Password（v8 / v7 / Safari拡張ホスト）
        "com.1password.",
        "com.agilebits.",
        // Apple パスワード（macOS 15+）・キーチェーンアクセス
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        // その他の主要パスワードマネージャー
        "com.bitwarden.",
        "org.keepassxc.",
        "com.lastpass.",
        "com.dashlane.",
        "in.sinew.Enpass",
        "com.mseven.msecure"
    ]

    /// 指定した bundle identifier がセンシティブなクライアントなら true。
    public static func isSensitive(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return prefixes.contains { bundleIdentifier.hasPrefix($0) }
    }
}
