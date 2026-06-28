import Foundation

/// Обнаруженный вопрос собеседника — триггер для пробуждения LLM.
public struct DetectedQuestion: Sendable {
    public let segment: TranscriptSegment
    public let question: String

    public init(segment: TranscriptSegment, question: String) {
        self.segment = segment
        self.question = question
    }
}

/// Релевантный кусок персонального контекста (RAG): результат поиска по профилю.
public struct ContextSnippet: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let text: String
    /// Близость к запросу (например, косинусная). Чем больше — тем релевантнее.
    public let score: Double
    public let sourceTitle: String

    public init(id: UUID = UUID(), text: String, score: Double, sourceTitle: String) {
        self.id = id
        self.text = text
        self.score = score
        self.sourceTitle = sourceTitle
    }
}

/// Готовая подсказка с метрикой задержки до первого токена.
public struct Suggestion: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let triggeringSegmentID: UUID?
    public var text: String
    public let model: String
    /// Задержка до первого токена, миллисекунды (целевой показатель 1–2 с).
    public var latencyMs: Int?
    public let createdAt: TimeInterval

    public init(
        id: UUID = UUID(),
        triggeringSegmentID: UUID?,
        text: String,
        model: String,
        latencyMs: Int?,
        createdAt: TimeInterval
    ) {
        self.id = id
        self.triggeringSegmentID = triggeringSegmentID
        self.text = text
        self.model = model
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }
}
