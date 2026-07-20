import Foundation

/// 入力中の無駄な LLM 呼び出しを減らすためのデバウンサ。
///
/// `schedule` を短時間に連続で呼ぶと、最後の呼び出しだけが `delay` 経過後に実行される。
/// 新しい `schedule` や `cancel` が来ると、進行中の待機はキャンセルされる。
public actor Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    /// - Parameter delayMilliseconds: 遅延（ミリ秒）。推奨 50〜100ms。
    public init(delayMilliseconds: Int = 80) {
        self.delay = .milliseconds(delayMilliseconds)
    }

    /// `delay` 経過後に `operation` を実行する。待機中に再度呼ばれると前回はキャンセルされる。
    public func schedule(_ operation: @escaping @Sendable () async -> Void) {
        self.task?.cancel()
        self.task = Task { [delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return // キャンセルされた
            }
            await operation()
        }
    }

    /// 進行中の待機をキャンセルする（確定・カーソル移動時に呼ぶ）。
    public func cancel() {
        self.task?.cancel()
        self.task = nil
    }
}
