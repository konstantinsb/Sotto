import Foundation

/// Накопитель сэмплов в фрагменты фиксированной длины (по умолчанию 0.1 с при 16 кГц).
/// Хвост короче кадра остаётся в буфере до следующего вызова — потерь нет.
public final class AudioChunker: @unchecked Sendable {
    public let chunkSize: Int
    private var pending: [Float] = []
    private let lock = NSLock()

    public init(sampleRate: Int = 16_000, chunkDuration: TimeInterval = 0.1) {
        self.chunkSize = max(1, Int(Double(sampleRate) * chunkDuration))
    }

    /// Добавить сэмплы, вернуть готовые кадры (может быть 0..N).
    public func push(_ samples: [Float]) -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        while pending.count >= chunkSize {
            chunks.append(Array(pending.prefix(chunkSize)))
            pending.removeFirst(chunkSize)
        }
        return chunks
    }

    /// Сколько сэмплов сейчас лежит в незавершённом хвосте.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}
