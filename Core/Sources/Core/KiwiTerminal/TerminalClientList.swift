import Foundation

/// Kiwi: ターミナルアプリの判定リスト。
///
/// ターミナル上ではシェル履歴由来のコマンドサジェスト・パス補完を有効にし、
/// 逆に英語確定の Kiwi 履歴への記録は行わない（通常アプリのサジェストが
/// シェルコマンドで汚れるのを防ぐ。コマンドのソースはシェル履歴が常に最新）。
public enum TerminalClientList {
    /// bundle identifier の前方一致で判定する。
    public static let prefixes: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.termius"
    ]

    /// 指定した bundle identifier がターミナルアプリなら true。
    public static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return prefixes.contains { bundleIdentifier.hasPrefix($0) }
    }
}
