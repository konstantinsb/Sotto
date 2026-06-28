import Foundation

/// Фейковый источник аудио: периодически отдаёт фрагменты тишины с разметкой источника.
/// Нужен в фазе 1, чтобы конвейер реально работал на потоке данных без реального захвата.
public struct FakeAudioCapture: AudioCapturing {
    private let source: AudioSource
    private let interval: Duration
    private let samplesPerChunk: Int
    /// Если задано — поток завершится после N фрагментов (удобно для тестов).
    private let finishAfter: Int?

    public init(
        source: AudioSource,
        interval: Duration = .milliseconds(200),
        samplesPerChunk: Int = 1600,
        finishAfter: Int? = nil
    ) {
        self.source = source
        self.interval = interval
        self.samplesPerChunk = samplesPerChunk
        self.finishAfter = finishAfter
    }

    public func stream() -> AsyncStream<AudioChunk> {
        let source = self.source
        let interval = self.interval
        let samplesPerChunk = self.samplesPerChunk
        let finishAfter = self.finishAfter
        return AsyncStream { continuation in
            let task = Task {
                var index = 0
                var time: TimeInterval = 0
                while !Task.isCancelled {
                    if let limit = finishAfter, index >= limit { break }
                    let chunk = AudioChunk(
                        source: source,
                        sampleRate: 16_000,
                        samples: [Float](repeating: 0, count: samplesPerChunk),
                        timestamp: time
                    )
                    continuation.yield(chunk)
                    index += 1
                    time += 0.1
                    do { try await Task.sleep(for: interval) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
