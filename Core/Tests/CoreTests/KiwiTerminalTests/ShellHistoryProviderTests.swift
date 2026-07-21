@testable import Core
import Foundation
import Testing

@Test func parseHistoryLineHandlesZshExtendedFormat() {
    #expect(ShellHistoryProvider.parseHistoryLine(": 1700000000:0;git status") == "git status")
    #expect(ShellHistoryProvider.parseHistoryLine("git log --oneline") == "git log --oneline")
    // 短すぎる行は除外
    #expect(ShellHistoryProvider.parseHistoryLine("ls") == nil)
    // パスワード様トークンを含む行は除外
    #expect(ShellHistoryProvider.parseHistoryLine("export TOKEN=abcDEF123xyz9") == nil)
    #expect(ShellHistoryProvider.parseHistoryLine("curl -u user:Passw0rd! https://example.com") == nil)
}

@Test func shellHistorySuggestMatchesPrefixByFrequency() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("KiwiTerminalTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let historyURL = directory.appendingPathComponent("zsh_history")
    try """
    git status
    git status
    git push origin main
    ls -la
    """.write(to: historyURL, atomically: true, encoding: .utf8)

    let provider = ShellHistoryProvider(fileURLs: [historyURL])
    let suggestions = provider.suggest(prefix: "git", limit: 3)
    #expect(suggestions.first == "git status") // 頻度2で最上位
    #expect(suggestions.contains("git push origin main"))
    #expect(!suggestions.contains("ls -la"))
    // 完全一致（入力そのまま）は返さない
    #expect(!provider.suggest(prefix: "git status", limit: 3).contains("git status"))
}

@Test func pathCompleterSuggestsDirectories() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("KiwiPathTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("projects", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data().write(to: directory.appendingPathComponent("readme.txt"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = directory.path

    // ディレクトリは末尾 / 付きで補完される
    let dirSuggestions = PathCompleter.suggest(composing: "cd \(base)/pro", limit: 3)
    #expect(dirSuggestions == ["cd \(base)/projects/"])

    // ファイルも補完される
    let fileSuggestions = PathCompleter.suggest(composing: "cat \(base)/read", limit: 3)
    #expect(fileSuggestions == ["cat \(base)/readme.txt"])

    // パスで始まらないトークンは対象外
    #expect(PathCompleter.suggest(composing: "git status", limit: 3).isEmpty)
}
