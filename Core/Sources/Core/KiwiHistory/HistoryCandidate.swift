import Foundation

/// 履歴から引き出した予測候補。
public struct HistoryCandidate: Sendable, Equatable {
    /// 読み（ひらがな）
    public var reading: String
    /// 表記
    public var surface: String
    /// 並び替えに用いるスコア（頻度 × 文脈類似度）。大きいほど上位。
    public var score: Double

    public init(reading: String, surface: String, score: Double) {
        self.reading = reading
        self.surface = surface
        self.score = score
    }
}
