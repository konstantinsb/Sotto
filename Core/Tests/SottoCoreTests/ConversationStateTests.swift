import XCTest
@testable import SottoCore

final class ConversationStateTests: XCTestCase {

    private func segment(_ text: String, source: AudioSource = .system, isFinal: Bool) -> TranscriptSegment {
        TranscriptSegment(source: source, text: text, isFinal: isFinal, start: 0, end: 1)
    }

    func testStateChangedUpdatesState() {
        var state = ConversationState()
        state.apply(.stateChanged(.listening))
        XCTAssertEqual(state.sessionState, .listening)
    }

    func testPartialThenFinalTranscript() {
        var state = ConversationState()
        state.apply(.transcript(.partial(segment("привет", isFinal: false))))
        XCTAssertEqual(state.partials[.system], "привет")
        XCTAssertTrue(state.finals.isEmpty)

        state.apply(.transcript(.final(segment("привет мир", isFinal: true))))
        XCTAssertNil(state.partials[.system])          // частичный очищен
        XCTAssertEqual(state.finals.count, 1)
        XCTAssertEqual(state.finals.first?.text, "привет мир")
    }

    func testSuggestionStreaming() {
        var state = ConversationState()
        let id = UUID()
        state.apply(.suggestionStarted(id: id))
        state.apply(.suggestionToken(id: id, token: "Я "))
        state.apply(.suggestionToken(id: id, token: "бы "))
        state.apply(.suggestionToken(id: id, token: "сделал"))
        XCTAssertEqual(state.currentSuggestion, "Я бы сделал")

        let suggestion = Suggestion(id: id, triggeringSegmentID: nil, text: "Я бы сделал", model: "m", latencyMs: 1200, createdAt: 0)
        state.apply(.suggestionCompleted(suggestion))
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertEqual(state.lastLatencyMs, 1200)
    }

    func testFinalsAreTrimmedToMax() {
        var state = ConversationState(maxFinals: 3)
        for i in 0..<5 {
            state.apply(.transcript(.final(segment("seg \(i)", isFinal: true))))
        }
        XCTAssertEqual(state.finals.count, 3)
        XCTAssertEqual(state.finals.map(\.text), ["seg 2", "seg 3", "seg 4"]) // старые вытеснены
    }

    func testFailureStored() {
        var state = ConversationState()
        state.apply(.failure("ошибка модели"))
        XCTAssertEqual(state.lastError, "ошибка модели")
    }

    func testResetClears() {
        var state = ConversationState()
        state.apply(.stateChanged(.listening))
        state.apply(.transcript(.final(segment("x", isFinal: true))))
        state.reset()
        XCTAssertEqual(state, ConversationState())
    }

    func testPartialsIsolatedPerSource() {
        var state = ConversationState()
        state.apply(.transcript(.partial(segment("я говорю", source: .microphone, isFinal: false))))
        state.apply(.transcript(.partial(segment("вопрос", source: .system, isFinal: false))))
        XCTAssertEqual(state.partials[.microphone], "я говорю")
        XCTAssertEqual(state.partials[.system], "вопрос")

        // final по одному источнику не трогает частичный другого
        state.apply(.transcript(.final(segment("вопрос?", source: .system, isFinal: true))))
        XCTAssertNil(state.partials[.system])
        XCTAssertEqual(state.partials[.microphone], "я говорю")
        XCTAssertEqual(state.finals.count, 1)
        XCTAssertEqual(state.finals.first?.source, .system)
    }

    func testSecondSuggestionStartedClearsLeftover() {
        var state = ConversationState()
        let first = UUID()
        state.apply(.suggestionStarted(id: first))
        state.apply(.suggestionToken(id: first, token: "часть "))
        XCTAssertEqual(state.currentSuggestion, "часть ")
        state.apply(.suggestionStarted(id: UUID()))   // новый вопрос затирает остаток
        XCTAssertEqual(state.currentSuggestion, "")
    }

    /// Параллельные потоки (спекуляция + финал / два вопроса подряд) эмитят токены с РАЗНЫМИ
    /// id вперемешку. Живой пузырь должен показывать только токены последнего начатого
    /// потока, а история — обе завершённые подсказки.
    func testInterleavedStreamsShowOnlyActiveIDInBubble() {
        var state = ConversationState()
        let a = UUID(), b = UUID()
        state.apply(.suggestionStarted(id: a))
        state.apply(.suggestionToken(id: a, token: "ответ-А "))
        state.apply(.suggestionStarted(id: b))                 // второй поток вытесняет первый
        state.apply(.suggestionToken(id: b, token: "ответ-Б "))
        state.apply(.suggestionToken(id: a, token: "хвост-А")) // запоздалый токен А — игнор
        XCTAssertEqual(state.currentSuggestion, "ответ-Б ", "пузырь — только активный поток")

        // обе завершённые подсказки попадают в историю (тексты не перепутаны)
        state.apply(.suggestionCompleted(Suggestion(id: a, triggeringSegmentID: nil, text: "ответ-А полный", model: "m", latencyMs: 1, createdAt: 0)))
        state.apply(.suggestionCompleted(Suggestion(id: b, triggeringSegmentID: nil, text: "ответ-Б полный", model: "m", latencyMs: 2, createdAt: 0)))
        XCTAssertEqual(state.suggestions.map(\.text), ["ответ-Б полный", "ответ-А полный"])
    }

    func testMultipleCompletionsNewestFirst() {
        var state = ConversationState()
        let first = Suggestion(id: UUID(), triggeringSegmentID: nil, text: "first", model: "m", latencyMs: 1000, createdAt: 0)
        let second = Suggestion(id: UUID(), triggeringSegmentID: nil, text: "second", model: "m", latencyMs: 2000, createdAt: 0)
        state.apply(.suggestionCompleted(first))
        state.apply(.suggestionCompleted(second))
        XCTAssertEqual(state.suggestions.map(\.text), ["second", "first"]) // новейшая сверху
        XCTAssertEqual(state.lastLatencyMs, 2000)
    }

    func testQuestionDetectedStoresLastQuestion() {
        var state = ConversationState()
        XCTAssertNil(state.lastQuestion)
        let segment = segment("Расскажите про дебаунс?", isFinal: true)
        state.apply(.questionDetected(DetectedQuestion(segment: segment, question: "Как сделать дебаунс?")))
        XCTAssertEqual(state.lastQuestion, "Как сделать дебаунс?")

        // Новый вопрос замещает прежний.
        state.apply(.questionDetected(DetectedQuestion(segment: segment, question: "А троттлинг?")))
        XCTAssertEqual(state.lastQuestion, "А троттлинг?")

        // Сброс сессии очищает.
        state.reset()
        XCTAssertNil(state.lastQuestion)
    }

    func testFailureKeepsSessionState() {
        var state = ConversationState()
        state.apply(.stateChanged(.thinking))
        state.apply(.failure("сбой"))
        XCTAssertEqual(state.sessionState, .thinking) // ошибка не сбрасывает состояние
        XCTAssertEqual(state.lastError, "сбой")
    }
}
