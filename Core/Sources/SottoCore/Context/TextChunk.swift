import Foundation

/// Кусок текста профиля с пометкой источника (секции).
public struct TextChunk: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let text: String
    public let sourceTitle: String

    public init(id: UUID = UUID(), text: String, sourceTitle: String) {
        self.id = id
        self.text = text
        self.sourceTitle = sourceTitle
    }
}

/// Чанк с оценкой релевантности (результат поиска).
public struct ScoredChunk: Sendable {
    public let chunk: TextChunk
    public let score: Double

    public init(chunk: TextChunk, score: Double) {
        self.chunk = chunk
        self.score = score
    }
}
