import Foundation

/// Фейковый движок расшифровки. Содержимое аудио игнорирует, но реально потребляет
/// входной поток и по мере прихода фрагментов «проявляет» заранее заданные фразы —
/// слово за словом как частичные гипотезы, затем фиксирует фразу целиком.
public struct FakeTranscriptionEngine: TranscriptionEngine {
    private let source: AudioSource
    private let script: [String]
    /// Сколько фрагментов аудио приходится на одно «распознанное» слово.
    private let chunksPerWord: Int

    public init(source: AudioSource, script: [String], chunksPerWord: Int = 2) {
        self.source = source
        self.script = script
        self.chunksPerWord = max(1, chunksPerWord)
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
        let source = self.source
        let script = self.script
        let chunksPerWord = self.chunksPerWord
        return AsyncStream { continuation in
            let task = Task {
                var phraseIndex = 0
                var words: [String] = script.first.map(Self.split) ?? []
                var wordCursor = 0
                var chunkCount = 0
                var phraseStart: TimeInterval = 0

                for await chunk in audio {
                    if Task.isCancelled { break }
                    guard phraseIndex < script.count else { continue }
                    chunkCount += 1
                    guard chunkCount % chunksPerWord == 0, wordCursor < words.count else { continue }

                    if wordCursor == 0 { phraseStart = chunk.timestamp }
                    wordCursor += 1

                    let partialText = words[0..<wordCursor].joined(separator: " ")
                    continuation.yield(.partial(TranscriptSegment(
                        source: source, text: partialText, isFinal: false,
                        start: phraseStart, end: chunk.timestamp
                    )))

                    if wordCursor == words.count {
                        continuation.yield(.final(TranscriptSegment(
                            source: source, text: words.joined(separator: " "), isFinal: true,
                            start: phraseStart, end: chunk.timestamp
                        )))
                        phraseIndex += 1
                        words = phraseIndex < script.count ? Self.split(script[phraseIndex]) : []
                        wordCursor = 0
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func split(_ phrase: String) -> [String] {
        phrase.split(separator: " ").map(String.init)
    }
}
