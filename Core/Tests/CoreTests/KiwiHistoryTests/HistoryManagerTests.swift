@testable import Core
import Foundation
import Testing

private func makeTemporaryManager() throws -> (HistoryManager, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("KiwiHistoryTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("history.sqlite", isDirectory: false)
    let manager = try HistoryManager(databaseURL: url)
    return (manager, directory)
}

@Test func recordAndPredictReturnsMostFrequent() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    manager.record(reading: "きょう", surface: "今日", leftContext: "")
    manager.record(reading: "きょう", surface: "今日", leftContext: "")
    manager.record(reading: "きょう", surface: "教養", leftContext: "")

    let candidates = manager.predict(reading: "きょう", leftContext: "", limit: 5)
    #expect(candidates.first?.surface == "今日")
    #expect(candidates.contains { $0.surface == "教養" })
}

@Test func recordAccumulatesFrequencyForSamePair() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    manager.record(reading: "きょう", surface: "今日", leftContext: "")
    manager.record(reading: "きょう", surface: "今日", leftContext: "")
    manager.record(reading: "きょう", surface: "今日", leftContext: "")

    // 同一 (reading, surface) は加算更新されるため 1 レコードのみ
    #expect(manager.count() == 1)
}

@Test func predictUsesPrefixMatch() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    manager.record(reading: "きょうと", surface: "京都", leftContext: "")
    let candidates = manager.predict(reading: "きょう", leftContext: "", limit: 5)
    #expect(candidates.contains { $0.surface == "京都" })
}

@Test func predictPrefersSimilarLeftContext() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    // 頻度は「東京」が上だが、文脈が一致する「今日」を優先させたい
    manager.record(reading: "きょう", surface: "京", leftContext: "旅行で")
    manager.record(reading: "きょう", surface: "京", leftContext: "旅行で")
    manager.record(reading: "きょう", surface: "今日", leftContext: "会議は")

    let candidates = manager.predict(reading: "きょう", leftContext: "会議は", limit: 5)
    #expect(candidates.first?.surface == "今日")
}

@Test func decayReducesFrequencyAndPrunes() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    manager.record(reading: "てすと", surface: "テスト", leftContext: "")
    // 1.0 から十分に減衰させると閾値以下になり削除される
    for _ in 0 ..< 40 {
        manager.decayAll(by: 0.9)
    }
    #expect(manager.count() == 0)
}

@Test func seedIfNeededAppliesNewVersionOnly() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    // v1 を投入
    manager.seedIfNeeded([("よろ", "よろしく")], version: 1)
    #expect(manager.count() == 1)

    // 同じバージョンでは再投入しない
    manager.seedIfNeeded([("よろ", "よろしく"), ("best", "Best regards,")], version: 1)
    #expect(manager.count() == 1)

    // 新しいバージョンなら差分（未存在分）だけ追加される
    manager.seedIfNeeded([("よろ", "よろしく"), ("best", "Best regards,")], version: 2)
    #expect(manager.count() == 2)

    // 英語シードは小文字読みでも前方一致で引ける
    let candidates = manager.predict(reading: "bes", leftContext: "", limit: 5)
    #expect(candidates.first?.surface == "Best regards,")
}

@Test func decayDailyRunsOncePerDay() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    manager.record(reading: "てすと", surface: "テスト", leftContext: "")
    manager.record(reading: "てすと", surface: "テスト", leftContext: "")
    // frequency = 2.0

    let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    // 同じ日に何度呼んでも減衰は 1 回だけ
    manager.decayDailyIfNeeded(now: day1, factor: 0.5)
    manager.decayDailyIfNeeded(now: day1, factor: 0.5)
    // score = frequency * (1 + similarity)。空文脈同士は similarity = 1 なので score = freq * 2。
    var candidates = manager.predict(reading: "てすと", leftContext: "", limit: 1)
    #expect(candidates.first?.score == 2.0) // freq: 2.0 → 1.0（1回だけ減衰）

    // 翌日はもう 1 回減衰する
    let day2 = day1.addingTimeInterval(60 * 60 * 24)
    manager.decayDailyIfNeeded(now: day2, factor: 0.5)
    candidates = manager.predict(reading: "てすと", leftContext: "", limit: 1)
    #expect(candidates.first?.score == 1.0) // freq: 1.0 → 0.5
}

@Test func emptyInputsAreIgnored() throws {
    let (manager, directory) = try makeTemporaryManager()
    defer { try? FileManager.default.removeItem(at: directory) }

    manager.record(reading: "", surface: "今日", leftContext: "")
    manager.record(reading: "きょう", surface: "", leftContext: "")
    #expect(manager.count() == 0)
    #expect(manager.predict(reading: "", leftContext: nil, limit: 5).isEmpty)
}

@Test func contextSimilarityBounds() {
    #expect(HistoryManager.contextSimilarity("", "") == 1.0)
    #expect(HistoryManager.contextSimilarity("あいう", "") == 0.0)
    #expect(HistoryManager.contextSimilarity("会議は", "会議は") == 1.0)
    let partial = HistoryManager.contextSimilarity("今日の会議は", "明日の会議は")
    #expect(partial > 0.0 && partial < 1.0)
}

@Test func escapeLikeEscapesWildcards() {
    #expect(HistoryManager.escapeLike("50%") == "50\\%")
    #expect(HistoryManager.escapeLike("a_b") == "a\\_b")
    #expect(HistoryManager.escapeLike("あ") == "あ")
}
