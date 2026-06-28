import Foundation

/// Состояние разговора для UI — чистый редьюсер событий сессии.
/// Вынесен из View-слоя, чтобы логику проекции `SessionEvent` → состояние
/// можно было покрыть тестами без UI.
public struct ConversationState: Sendable, Equatable {
    public var sessionState: SessionState = .idle
    public var finals: [TranscriptSegment] = []
    public var partials: [AudioSource: String] = [:]
    public var currentSuggestion: String = ""
    /// Текст последнего распознанного вопроса собеседника (триггер подсказки). Показывается
    /// Q-чипом в оверлее; держится до следующего вопроса или сброса сессии.
    public var lastQuestion: String?
    public var suggestions: [Suggestion] = []
    public var lastLatencyMs: Int?
    public var lastError: String?

    /// id потока, чьи токены сейчас показываем в живом пузыре. Несколько генераций могут
    /// идти параллельно (спекуляция + финал, или два вопроса подряд) и эмитить токены
    /// вперемешку — показываем только токены последнего начатого потока, иначе их тексты
    /// склеились бы в один искажённый ответ.
    private var activeSuggestionID: UUID?

    /// Максимум хранимых зафиксированных сегментов (обрезаем историю).
    public var maxFinals: Int

    public init(maxFinals: Int = 50) {
        self.maxFinals = max(0, maxFinals)
    }

    public mutating func apply(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let state):
            sessionState = state
        case .transcript(let transcriptEvent):
            applyTranscript(transcriptEvent)
        case .questionDetected(let detected):
            lastQuestion = detected.question
        case .suggestionStarted(let id):
            activeSuggestionID = id
            currentSuggestion = ""
        case .suggestionToken(let id, let token):
            // Токены неактивного (вытесненного/отменённого) потока игнорируем — иначе
            // параллельные ответы склеились бы в один искажённый текст.
            guard id == activeSuggestionID else { break }
            currentSuggestion += token
        case .suggestionCompleted(let suggestion):
            suggestions.insert(suggestion, at: 0)
            lastLatencyMs = suggestion.latencyMs
            if suggestion.id == activeSuggestionID { activeSuggestionID = nil }
        case .failure(let message):
            lastError = message
        }
    }

    private mutating func applyTranscript(_ event: TranscriptEvent) {
        switch event {
        case .partial(let segment):
            partials[segment.source] = segment.text
        case .final(let segment):
            partials[segment.source] = nil
            finals.append(segment)
            if finals.count > maxFinals {
                finals.removeFirst(finals.count - maxFinals)
            }
        }
    }

    /// Сброс перед новой сессией (метаданные обрезки сохраняются).
    public mutating func reset() {
        sessionState = .idle
        finals.removeAll()
        partials.removeAll()
        currentSuggestion = ""
        lastQuestion = nil
        activeSuggestionID = nil
        suggestions.removeAll()
        lastLatencyMs = nil
        lastError = nil
    }
}
