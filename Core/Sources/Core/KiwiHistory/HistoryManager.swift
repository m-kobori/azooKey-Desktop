import Foundation
import GRDB

/// Kiwi の予測変換・履歴学習の基盤。
///
/// 確定した「読み→表記」ペアをローカル SQLite に保存し、頻度と文脈に基づいて
/// 次回の変換候補を引き出す。ネットワークには一切送信しない。
///
/// - Important: 履歴保存はベストエフォート。DB エラーが発生しても入力体験を妨げないよう、
///   書き込み・読み込みの失敗は握りつぶし（ログのみ）、呼び出し側に例外を伝播させない。
/// - Note: `DatabaseQueue` はシリアルアクセスを保証するため、複数スレッドから安全に利用できる。
public final class HistoryManager: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let logger: (@Sendable (String) -> Void)?

    /// 頻度がこの値を下回った行は減衰処理で削除する。
    private static let minimumFrequency: Double = 0.05

    /// 任意の DB ファイルパスで初期化する（主にテスト用）。
    public init(databaseURL: URL, logger: (@Sendable (String) -> Void)? = nil) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(2.0)
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        self.logger = logger
        try Self.migrate(dbQueue)
    }

    /// アプリの Sandbox コンテナ配下に履歴 DB を作成する。
    ///
    /// 保存先: `<container>/Library/Application Support/KiwiHistory/history.sqlite`
    public convenience init(containerURL: URL, logger: (@Sendable (String) -> Void)? = nil) throws {
        let directory = containerURL
            .appendingPathComponent("Library/Application Support/KiwiHistory", isDirectory: true)
        try self.init(databaseURL: directory.appendingPathComponent("history.sqlite", isDirectory: false), logger: logger)
    }

    // MARK: - Schema

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createHistory") { db in
            try db.create(table: "history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("reading", .text).notNull()
                t.column("surface", .text).notNull()
                t.column("leftContext", .text).notNull().defaults(to: "")
                t.column("rightContext", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("frequency", .double).notNull().defaults(to: 1.0)
                t.column("source", .text).notNull().defaults(to: "ime")
            }
            // 前方一致検索の高速化
            try db.create(index: "index_history_reading", on: "history", columns: ["reading"], ifNotExists: true)
            // (reading, surface) は一意。record は同一ペアを加算更新する。
            try db.create(
                index: "index_history_reading_surface",
                on: "history",
                columns: ["reading", "surface"],
                unique: true,
                ifNotExists: true
            )
        }
        // 減衰の最終実行日などのメタ情報（key-value）。
        migrator.registerMigration("createMeta") { db in
            try db.create(table: "meta", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Write

    /// 確定した変換を記録する。
    ///
    /// 同じ `(reading, surface)` が既に存在すれば `frequency` を加算し、文脈・時刻を更新する。
    /// 無ければ新規挿入する。キャンセル/Backspace 確定など、誤変換は呼び出し側で除外すること。
    public func record(
        reading: String,
        surface: String,
        leftContext: String = "",
        rightContext: String? = nil,
        source: String = "ime",
        at date: Date = Date()
    ) {
        guard !reading.isEmpty, !surface.isEmpty else { return }
        do {
            try dbQueue.write { db in
                if var existing = try HistoryEntry
                    .filter(HistoryEntry.Columns.reading == reading && HistoryEntry.Columns.surface == surface)
                    .fetchOne(db) {
                    existing.frequency += 1.0
                    existing.timestamp = date
                    existing.leftContext = leftContext
                    existing.rightContext = rightContext
                    try existing.update(db)
                } else {
                    var entry = HistoryEntry(
                        reading: reading,
                        surface: surface,
                        leftContext: leftContext,
                        rightContext: rightContext,
                        timestamp: date,
                        frequency: 1.0,
                        source: source
                    )
                    try entry.insert(db)
                }
            }
        } catch {
            self.logger?("HistoryManager.record failed: \(error)")
        }
    }

    // MARK: - Read

    /// 読みの前方一致で履歴候補を返す。頻度が高く、文脈が似ているものほど上位にする。
    public func predict(reading: String, leftContext: String? = nil, limit: Int = 5) -> [HistoryCandidate] {
        guard !reading.isEmpty, limit > 0 else { return [] }
        do {
            let entries = try dbQueue.read { db in
                try HistoryEntry
                    .filter(HistoryEntry.Columns.reading.like(Self.escapeLike(reading) + "%", escape: "\\"))
                    .order(HistoryEntry.Columns.frequency.desc, HistoryEntry.Columns.timestamp.desc)
                    // 文脈類似で再ランクするため、多めに取得してから絞る
                    .limit(max(limit * 4, limit))
                    .fetchAll(db)
            }
            let context = leftContext ?? ""
            let ranked = entries
                .map { entry -> (candidate: HistoryCandidate, similarity: Double) in
                    let similarity = Self.contextSimilarity(context, entry.leftContext)
                    let candidate = HistoryCandidate(
                        reading: entry.reading,
                        surface: entry.surface,
                        score: entry.frequency * (1.0 + similarity)
                    )
                    return (candidate, similarity)
                }
                // スコア同点は文脈類似が高い方を優先（sorted は安定ソートでないため明示的に決める）。
                .sorted {
                    if $0.candidate.score != $1.candidate.score {
                        return $0.candidate.score > $1.candidate.score
                    }
                    return $0.similarity > $1.similarity
                }
                .map(\.candidate)
            return Array(ranked.prefix(limit))
        } catch {
            self.logger?("HistoryManager.predict failed: \(error)")
            return []
        }
    }

    // MARK: - Maintenance

    /// 全レコードの頻度を減衰させる（例: 毎日1回 0.9 倍）。
    /// 十分に小さくなった行は削除して DB を肥大化させない。
    public func decayAll(by factor: Double = 0.9) {
        guard factor > 0, factor < 1 else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE history SET frequency = frequency * ?", arguments: [factor])
                try db.execute(sql: "DELETE FROM history WHERE frequency < ?", arguments: [Self.minimumFrequency])
            }
        } catch {
            self.logger?("HistoryManager.decayAll failed: \(error)")
        }
    }

    /// meta テーブルの最終減衰日キー。
    private static let lastDecayDateKey = "lastDecayDate"

    /// 1日1回だけ `decayAll` を実行する。
    ///
    /// 最終実行日（ローカルタイムゾーンの暦日 "yyyy-MM-dd"）を DB 内 meta テーブルに保持し、
    /// 日付が変わっていた場合のみ減衰する。判定と減衰を同一トランザクションで行うため、
    /// 複数プロセス/スレッドから同時に呼ばれても二重減衰しない。起動時などに呼ぶ。
    public func decayDailyIfNeeded(now: Date = Date(), factor: Double = 0.9) {
        guard factor > 0, factor < 1 else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        do {
            try dbQueue.write { db in
                let last = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM meta WHERE key = ?",
                    arguments: [Self.lastDecayDateKey]
                )
                guard last != today else { return }
                try db.execute(sql: "UPDATE history SET frequency = frequency * ?", arguments: [factor])
                try db.execute(sql: "DELETE FROM history WHERE frequency < ?", arguments: [Self.minimumFrequency])
                try db.execute(
                    sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [Self.lastDecayDateKey, today]
                )
            }
        } catch {
            self.logger?("HistoryManager.decayDailyIfNeeded failed: \(error)")
        }
    }

    /// 保存件数（テスト・デバッグ用）。
    public func count() -> Int {
        (try? dbQueue.read { db in try HistoryEntry.fetchCount(db) }) ?? 0
    }

    /// meta テーブルの投入済みシードバージョンキー。
    private static let seedVersionKey = "seedVersion"

    /// 初期データ（定型句など）を、まだ投入していないバージョン分だけ投入する。
    ///
    /// コールドスタート（該当読みの履歴が無く予測に何も出ない）を避けるため、起動時に呼ぶ。
    /// meta テーブルの `seedVersion` と `version` を比較し、新しい場合のみ差分投入する
    /// （＝リリース後にシードを追加しても、既存 DB へ次回起動時に自動で追加される）。
    /// 後方互換: バージョン未記録でも `source="seed"` の行が既にあれば v1 投入済みとみなす。
    /// `source="seed"` かつ低頻度（0.5）なので、実利用の学習（"ime"）が優先され、
    /// 同一 (reading, surface) が既にあれば重複挿入しない（ユニーク制約）。
    public func seedIfNeeded(
        _ entries: [(reading: String, surface: String)],
        version: Int = HistorySeedData.version,
        source: String = "seed"
    ) {
        do {
            try dbQueue.write { db in
                let storedVersion = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM meta WHERE key = ?",
                    arguments: [Self.seedVersionKey]
                ).flatMap(Int.init) ?? 0
                let hasSeedRows = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(HistoryEntry.databaseTableName) WHERE source = ?",
                    arguments: [source]
                ) ?? 0) > 0
                // 旧ロジック（バージョン管理以前）で投入済みの DB は v1 とみなす。
                let effectiveVersion = (storedVersion == 0 && hasSeedRows) ? 1 : storedVersion
                guard effectiveVersion < version else { return }
                for entry in entries where !entry.reading.isEmpty && !entry.surface.isEmpty {
                    // 同一 (reading, surface) の重複はスキップ（ユニーク制約）。
                    let exists = try HistoryEntry
                        .filter(HistoryEntry.Columns.reading == entry.reading && HistoryEntry.Columns.surface == entry.surface)
                        .fetchCount(db) > 0
                    guard !exists else { continue }
                    var record = HistoryEntry(
                        reading: entry.reading,
                        surface: entry.surface,
                        leftContext: "",
                        rightContext: nil,
                        timestamp: Date(timeIntervalSince1970: 0),
                        frequency: 0.5,
                        source: source
                    )
                    try record.insert(db)
                }
                try db.execute(
                    sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [Self.seedVersionKey, String(version)]
                )
            }
        } catch {
            self.logger?("HistoryManager.seedIfNeeded failed: \(error)")
        }
    }

    /// 全履歴を削除する（設定画面からのクリア用）。
    public func clear() {
        do {
            try dbQueue.write { db in
                _ = try HistoryEntry.deleteAll(db)
            }
        } catch {
            self.logger?("HistoryManager.clear failed: \(error)")
        }
    }

    // MARK: - Helpers

    /// LIKE のワイルドカード文字をエスケープする。
    static func escapeLike(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\", "%", "_":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    /// 2つの文脈の末尾一致長を、短い方の長さで正規化した類似度 [0, 1]。
    static func contextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1.0 }
        if lhs.isEmpty || rhs.isEmpty { return 0.0 }
        let left = Array(lhs)
        let right = Array(rhs)
        var matched = 0
        while matched < left.count && matched < right.count,
              left[left.count - 1 - matched] == right[right.count - 1 - matched] {
            matched += 1
        }
        return Double(matched) / Double(min(left.count, right.count))
    }
}
