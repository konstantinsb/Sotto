import Foundation
import SwiftData

/// Сохранённая сессия. Чувствительные тексты — в зашифрованных полях (`*Ciphertext`).
@Model
final class StoredSession {
    var id: UUID
    var startedAt: Date
    var mode: String
    var summaryCiphertext: Data?

    @Relationship(deleteRule: .cascade, inverse: \StoredSegment.session)
    var segments: [StoredSegment]

    @Relationship(deleteRule: .cascade, inverse: \StoredSuggestion.session)
    var suggestions: [StoredSuggestion]

    init(id: UUID = UUID(), startedAt: Date, mode: String, summaryCiphertext: Data? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.mode = mode
        self.summaryCiphertext = summaryCiphertext
        self.segments = []
        self.suggestions = []
    }
}

@Model
final class StoredSegment {
    var source: String
    var textCiphertext: Data
    var order: Int
    var session: StoredSession?

    init(source: String, textCiphertext: Data, order: Int) {
        self.source = source
        self.textCiphertext = textCiphertext
        self.order = order
    }
}

@Model
final class StoredSuggestion {
    var textCiphertext: Data
    var model: String
    var latencyMs: Int?
    var createdAt: Date
    var session: StoredSession?

    init(textCiphertext: Data, model: String, latencyMs: Int?, createdAt: Date) {
        self.textCiphertext = textCiphertext
        self.model = model
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }
}
