@testable import Core
import Foundation
import Testing

/// 呼び出し回数を数え、固定応答を返すモックバックエンド。
private final class MockBackend: LLMRevisionBackend, @unchecked Sendable {
    let response: String
    let available: Bool
    private let lock = NSLock()
    private var _callCount = 0

    init(response: String, available: Bool = true) {
        self.response = response
        self.available = available
    }

    var isAvailable: Bool { self.available }

    var callCount: Int {
        self.lock.lock(); defer { self.lock.unlock() }
        return self._callCount
    }

    func generate(prompt: String) async throws -> String {
        self.lock.lock(); self._callCount += 1; self.lock.unlock()
        return self.response
    }
}

// MARK: - Sanitize

@Test func sanitizeMasksSensitiveTokens() {
    let input = "詳細は https://example.com/path と user@example.com へ。番号は 12345678、パスは /Users/foo/bar"
    let output = LLMReviser.sanitizeContext(input)
    #expect(!output.contains("https://example.com"))
    #expect(!output.contains("user@example.com"))
    #expect(!output.contains("12345678"))
    #expect(!output.contains("/Users/foo/bar"))
    #expect(output.contains("[URL]"))
    #expect(output.contains("[EMAIL]"))
    #expect(output.contains("[NUMBER]"))
    #expect(output.contains("[PATH]"))
}

@Test func sanitizeKeepsShortNumbers() {
    // 3桁以下は伏せない
    let output = LLMReviser.sanitizeContext("部屋は12号室")
    #expect(output.contains("12"))
}

@Test func meaningfulLengthIgnoresPlaceholders() {
    #expect(LLMReviser.meaningfulLength(of: "[URL] [EMAIL]") == 0)
    #expect(LLMReviser.meaningfulLength(of: "今日は[URL]") == 3)
}

// MARK: - Parse

@Test func parseCandidatesFromObject() {
    let raw = #"{"candidates": ["今日は", "京都は"]}"#
    #expect(LLMReviser.parseCandidates(from: raw) == ["今日は", "京都は"])
}

@Test func parseCandidatesFromBareArray() {
    let raw = #"["今日", "教養"]"#
    #expect(LLMReviser.parseCandidates(from: raw) == ["今日", "教養"])
}

@Test func parseCandidatesStripsCodeFence() {
    let raw = "```json\n{\"candidates\": [\"晴れ\"]}\n```"
    #expect(LLMReviser.parseCandidates(from: raw) == ["晴れ"])
}

@Test func parseCandidatesReturnsEmptyOnGarbage() {
    #expect(LLMReviser.parseCandidates(from: "not json at all").isEmpty)
}

// MARK: - dedupe / merge

@Test func dedupePreservesOrder() {
    #expect(LLMReviser.dedupe(["a", "b", "a", "", "c", "b"]) == ["a", "b", "c"])
}

@Test func mergePutsExistingFirstAndAppendsNew() {
    let existing = ["今日", "教養"]
    let revised = [LLMRevisedCandidate(surface: "今日"), LLMRevisedCandidate(surface: "京")]
    #expect(LLMReviser.merge(existing: existing, revised: revised, maxResults: 5) == ["今日", "教養", "京"])
}

@Test func mergeRespectsMaxResults() {
    let existing = ["a", "b"]
    let revised = [LLMRevisedCandidate(surface: "c"), LLMRevisedCandidate(surface: "d")]
    #expect(LLMReviser.merge(existing: existing, revised: revised, maxResults: 3) == ["a", "b", "c"])
}

// MARK: - revise / cache

@Test func reviseReturnsParsedCandidates() async throws {
    let backend = MockBackend(response: #"{"candidates": ["今日は", "京都は"]}"#)
    let reviser = LLMReviser(backend: backend)
    let result = try await reviser.revise(reading: "きょうは", leftContext: "会議は", existingCandidates: ["今日は"], maxResults: 3)
    #expect(result.map(\.surface) == ["今日は", "京都は"])
}

@Test func reviseUsesCacheForSameInput() async throws {
    let backend = MockBackend(response: #"{"candidates": ["今日"]}"#)
    let reviser = LLMReviser(backend: backend)
    _ = try await reviser.revise(reading: "きょう", leftContext: "", existingCandidates: [], maxResults: 1)
    _ = try await reviser.revise(reading: "きょう", leftContext: "", existingCandidates: [], maxResults: 1)
    // 2回目はキャッシュから返り、バックエンドは1回しか呼ばれない
    #expect(backend.callCount == 1)
}

@Test func reviseRespectsMaxResults() async throws {
    let backend = MockBackend(response: #"{"candidates": ["a", "b", "c", "d"]}"#)
    let reviser = LLMReviser(backend: backend)
    let result = try await reviser.revise(reading: "test", leftContext: nil, existingCandidates: [], maxResults: 2)
    #expect(result.count == 2)
}

@Test func reviseReturnsEmptyWhenBackendUnavailable() async throws {
    let backend = MockBackend(response: #"{"candidates": ["x"]}"#, available: false)
    let reviser = LLMReviser(backend: backend)
    let result = try await reviser.revise(reading: "test", leftContext: nil, existingCandidates: [], maxResults: 3)
    #expect(result.isEmpty)
    #expect(backend.callCount == 0)
}

@Test func reviseReturnsEmptyForEmptyReading() async throws {
    let backend = MockBackend(response: #"{"candidates": ["x"]}"#)
    let reviser = LLMReviser(backend: backend)
    let result = try await reviser.revise(reading: "", leftContext: nil, existingCandidates: [], maxResults: 3)
    #expect(result.isEmpty)
    #expect(backend.callCount == 0)
}
