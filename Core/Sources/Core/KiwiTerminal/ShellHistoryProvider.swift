import Foundation

/// Kiwi: シェル履歴（zsh / bash）からコマンドサジェストを提供する。
///
/// ターミナル上の英語 composing で、打ち始めに前方一致する過去のコマンド行を返す。
/// - ローカルファイルの読み取りのみ（ネットワーク送信なし）。
/// - パスワード様のトークンを含む行は `HistoryPrivacyFilter` で除外する。
/// - 履歴ファイルの mtime が変わったときだけ再読込する（毎キー I/O を避ける）。
public final class ShellHistoryProvider: @unchecked Sendable {
    /// コマンド行 → 出現回数（新しい行ほど後で読まれ、同率時の優先に使う）。
    private struct Entry {
        var command: String
        var count: Int
        var lastIndex: Int
    }

    private let fileURLs: [URL]
    private let queue = DispatchQueue(label: "ShellHistoryProvider")
    private var entries: [Entry] = []
    private var lastModificationDates: [URL: Date] = [:]

    /// 既定では ~/.zsh_history と ~/.bash_history を読む。
    public init(fileURLs: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileURLs = fileURLs ?? [
            home.appendingPathComponent(".zsh_history"),
            home.appendingPathComponent(".bash_history")
        ]
    }

    /// 打ち始め `prefix` に前方一致するコマンド行を頻度順で返す。
    public func suggest(prefix: String, limit: Int = 3) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, limit > 0 else { return [] }
        return queue.sync {
            self.reloadIfNeeded()
            return self.entries
                .filter { $0.command.hasPrefix(trimmed) && $0.command != trimmed }
                .sorted {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.lastIndex > $1.lastIndex
                }
                .prefix(limit)
                .map(\.command)
        }
    }

    // MARK: - Load

    private func reloadIfNeeded() {
        var needsReload = false
        for url in fileURLs {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if mtime != lastModificationDates[url] {
                lastModificationDates[url] = mtime
                needsReload = true
            }
        }
        guard needsReload else { return }

        var counts: [String: Entry] = [:]
        var index = 0
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            // zsh 履歴は不正な UTF-8 バイトを含みうるため、損失許容でデコードする。
            let content = String(decoding: data, as: UTF8.self)
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let command = Self.parseHistoryLine(String(line)) else { continue }
                index += 1
                if var entry = counts[command] {
                    entry.count += 1
                    entry.lastIndex = index
                    counts[command] = entry
                } else {
                    counts[command] = Entry(command: command, count: 1, lastIndex: index)
                }
            }
        }
        self.entries = Array(counts.values)
    }

    /// 1 行をコマンドとして解釈する。zsh 拡張形式（`: <ts>:<dur>;cmd`）と素の行の両方に対応。
    /// 短すぎる行・機密様トークンを含む行は除外する。
    static func parseHistoryLine(_ line: String) -> String? {
        var command = line
        // zsh EXTENDED_HISTORY: ": 1700000000:0;git status"
        if command.hasPrefix(": "), let semicolon = command.firstIndex(of: ";") {
            command = String(command[command.index(after: semicolon)...])
        }
        command = command.trimmingCharacters(in: .whitespaces)
        guard command.count >= 3, command.count <= 200 else { return nil }
        // パスワード様のトークン（環境変数代入の値・認証情報など）を含む行は除外。
        // シェルではフラグ（--oneline）やパス（~/x, ./x）が機密判定に誤ヒットしやすいため、
        // それらは対象外とし、数字を含むトークンのみ HistoryPrivacyFilter で判定する。
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "=" })
        let containsSensitiveToken = tokens.contains { token in
            let text = String(token)
            if text.hasPrefix("-") || text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix(".") {
                return false
            }
            return text.contains(where: \.isNumber) && HistoryPrivacyFilter.isSensitiveText(text)
        }
        guard !containsSensitiveToken else { return nil }
        return command
    }
}
