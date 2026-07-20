import Foundation
import GRDB

/// 確定された「読み→表記」ペア1件を表す履歴レコード。
///
/// - Note: `reading` はひらがなに正規化して保存する（将来の入力照合と一致させるため）。
///   `leftContext` は確定直前の文脈（同一行・トリム済み、最大 ~30文字）を想定する。
public struct HistoryEntry: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    /// 主キー（自動採番）。挿入前は `nil`。
    public var id: Int64?
    /// 読み（ひらがな）
    public var reading: String
    /// 確定文字列（表記）
    public var surface: String
    /// 直前の文脈
    public var leftContext: String
    /// 直後の文脈（任意）
    public var rightContext: String?
    /// 最終確定時刻
    public var timestamp: Date
    /// 頻度スコア（確定のたびに加算し、時間経過で減衰させる）
    public var frequency: Double
    /// 由来（"ime" など）
    public var source: String

    public static let databaseTableName = "history"

    public init(
        id: Int64? = nil,
        reading: String,
        surface: String,
        leftContext: String = "",
        rightContext: String? = nil,
        timestamp: Date,
        frequency: Double = 1.0,
        source: String = "ime"
    ) {
        self.id = id
        self.reading = reading
        self.surface = surface
        self.leftContext = leftContext
        self.rightContext = rightContext
        self.timestamp = timestamp
        self.frequency = frequency
        self.source = source
    }

    /// GRDB: 挿入後に採番された rowID を反映する。
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    enum Columns {
        static let reading = Column(CodingKeys.reading)
        static let surface = Column(CodingKeys.surface)
        static let leftContext = Column(CodingKeys.leftContext)
        static let timestamp = Column(CodingKeys.timestamp)
        static let frequency = Column(CodingKeys.frequency)
    }
}
