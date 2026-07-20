import Foundation

/// Kiwi: パスワード等の機密らしき文字列を履歴に保存しないためのフィルタ。
///
/// パスワード欄の多く（Secure Input）には IME 自体が関与しないが、
/// Web フォームや一部アプリでは通常入力としてパスワードが打たれることがある。
/// 特に英語モードは確定テキストをそのまま履歴に記録するため、
/// 「パスワードらしい文字列」を記録前に弾き、既存 DB からも遡及削除する。
///
/// 判定は保守的（疑わしきは弾く）: 記録漏れの損失は小さく、漏洩の損失は大きい。
public enum HistoryPrivacyFilter {
    /// パスワード・PIN・API キー等の機密らしき文字列なら true。
    ///
    /// ルール（ASCII のみ・空白なしの文字列が対象。日本語文や空白入りフレーズは対象外）:
    /// - 数字のみで 6 文字以上（PIN・カード番号など）
    /// - 8 文字以上で、文字種（小文字/大文字/数字/記号）が 2 種類以上（典型的なパスワード）
    public static func isSensitiveText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 空白を含む（＝フレーズ）や非 ASCII（＝日本語等）は対象外
        guard trimmed.allSatisfy({ $0.isASCII }), !trimmed.contains(where: \.isWhitespace) else {
            return false
        }

        let hasLower = trimmed.contains { $0.isLowercase }
        let hasUpper = trimmed.contains { $0.isUppercase }
        let hasDigit = trimmed.contains { $0.isNumber }
        let hasSymbol = trimmed.contains { !$0.isLetter && !$0.isNumber }

        // 数字のみ 6 文字以上（PIN・番号列）
        if hasDigit, !hasLower, !hasUpper, !hasSymbol, trimmed.count >= 6 {
            return true
        }

        // 8 文字以上で文字種 2 種類以上
        let classCount = [hasLower, hasUpper, hasDigit, hasSymbol].count(where: { $0 })
        if trimmed.count >= 8, classCount >= 2 {
            return true
        }

        return false
    }
}
