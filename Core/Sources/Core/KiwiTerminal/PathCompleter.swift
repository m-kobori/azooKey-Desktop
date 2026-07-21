import Foundation

/// Kiwi: ターミナル向けのパス（ディレクトリ/ファイル）補完。
///
/// 入力中テキストの最後のトークンが `~` / `/` / `./` で始まるパスのとき、
/// ファイルシステムから補完候補を生成し、「行全体の置き換えテキスト」を返す
/// （サジェスト確定は composing 全体を置き換えるため）。ローカル読み取りのみ。
public enum PathCompleter {
    /// `composing`（入力中の行全体）に対するパス補完候補を返す。
    /// 例: "cd ~/pro" → ["cd ~/projects/"]。補完対象がなければ空。
    public static func suggest(composing: String, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        // 最後の空白区切りトークンを補完対象にする（行頭がパスの場合も含む）。
        let lastToken: Substring
        let head: Substring
        if let lastSpace = composing.lastIndex(of: " ") {
            lastToken = composing[composing.index(after: lastSpace)...]
            head = composing[...lastSpace]
        } else {
            lastToken = composing[...]
            head = ""
        }
        let token = String(lastToken)
        guard token.hasPrefix("~") || token.hasPrefix("/") || token.hasPrefix("./") else {
            return []
        }

        // ディレクトリ部分と入力途中の名前部分に分ける。
        let expanded = (token as NSString).expandingTildeInPath
        let directoryPath: String
        let namePrefix: String
        if expanded.hasSuffix("/") {
            directoryPath = expanded
            namePrefix = ""
        } else {
            directoryPath = (expanded as NSString).deletingLastPathComponent
            namePrefix = (expanded as NSString).lastPathComponent
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            return []
        }

        // 前方一致（大文字小文字は無視）。隠しファイルは、明示的に "." を打ち始めた時だけ出す。
        let matches = names
            .filter { name in
                (namePrefix.isEmpty ? !name.hasPrefix(".") : name.lowercased().hasPrefix(namePrefix.lowercased()))
            }
            .sorted()
            .prefix(limit)

        // 表示・確定用に「行全体」を再構成する。~ 始まりの入力は ~ 表記を保つ。
        let tokenDirectory: String
        if let lastSlash = token.lastIndex(of: "/") {
            tokenDirectory = String(token[...lastSlash])
        } else {
            tokenDirectory = ""
        }
        return matches.map { name in
            var completedPath = tokenDirectory + name
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: directoryPath + "/" + name, isDirectory: &isDir), isDir.boolValue {
                completedPath += "/"
            }
            return String(head) + completedPath
        }
    }
}
