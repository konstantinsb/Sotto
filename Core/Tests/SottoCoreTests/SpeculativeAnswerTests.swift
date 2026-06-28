import XCTest
@testable import SottoCore

/// A6: спекулятивный старт ответа на частичной (ещё не зафиксированной) расшифровке +
/// сверка с финалом (без дублей), и A5d: режим без RAG на критическом пути.
final class SpeculativeAnswerTests: XCTestCase {

    private func makeSession(
        events: [TranscriptEvent],
        gap: Duration = .milliseconds(15),
        speculate: Bool = true,
        useContext: Bool = true,
        cooldown: Duration = .milliseconds(1200),
        context: any ContextProviding = FakeContextEngine()
    ) -> SessionActor {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 400),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 400),
            micTranscription: FakeTranscriptionEngine(source: .microphone, script: []),
            systemTranscription: ScriptedTranscription(events: events, gap: gap),
            detector: HeuristicQuestionDetector(),
            context: context,
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1), answer: "ответ по делу"),
            promptBuilder: PromptBuilder()
        )
        return SessionActor(
            configuration: SessionConfiguration(
                mode: .iosInterview,
                systemPrompt: "s",
                speculateOnPartials: speculate,
                speculationCooldown: cooldown
            ).with(useContextRetrieval: useContext),
            dependencies: deps
        )
    }

    private func event(_ text: String, isFinal: Bool) -> TranscriptEvent {
        let seg = TranscriptSegment(source: .system, text: text, isFinal: isFinal, start: 0, end: 1)
        return isFinal ? .final(seg) : .partial(seg)
    }

    /// Партиал-вопрос (с «?») запускает ответ ДО какого-либо финала: финала нет вовсе,
    /// но подсказка всё равно генерируется — значит сработала спекуляция.
    func testSpeculativeStartOnPartialOnly() async {
        let session = makeSession(events: [event("как вы тестируете код?", isFinal: false)])
        let completed = await firstSuggestion(from: session, timeout: .seconds(2))
        await session.stop()
        XCTAssertNotNil(completed, "спекуляция на партиале должна дать подсказку без финала")
    }

    /// При выключенной спекуляции тот же партиал-вопрос (без финала) НЕ должен будить LLM.
    func testNoSpeculationWhenDisabled() async {
        let session = makeSession(
            events: [event("как вы тестируете код?", isFinal: false)],
            speculate: false
        )
        let completed = await firstSuggestion(from: session, timeout: .milliseconds(800))
        await session.stop()
        XCTAssertNil(completed, "без спекуляции партиал не должен порождать подсказку")
    }

    /// Партиал-вопрос, затем идентичный финал → ровно ОДНА подсказка (без дубля).
    func testFinalMatchingSpeculationDoesNotDuplicate() async {
        let session = makeSession(events: [
            event("как вы тестируете код?", isFinal: false),
            event("как вы тестируете код?", isFinal: true)
        ], gap: .milliseconds(40))

        let counter = Counter()
        let stream = await session.start()
        let consume = Task {
            for await event in stream {
                if case .suggestionCompleted = event { await counter.increment() }
            }
        }
        try? await Task.sleep(for: .seconds(2))   // окно сбора: успеет прийти и дубль, если он есть
        await session.stop()                        // закрывает поток событий → consume завершится
        consume.cancel()
        let count = await counter.value
        XCTAssertEqual(count, 1, "финал, совпавший со спекуляцией, не должен дублировать подсказку")
    }

    /// A5d: при useContextRetrieval=false RAG (topK) не вызывается, но подсказка есть.
    func testLowLatencyModeSkipsContextRetrieval() async {
        let spy = SpyContext()
        let session = makeSession(
            events: [event("как вы тестируете код?", isFinal: true)],
            speculate: false,
            useContext: false,
            context: spy
        )
        let completed = await firstSuggestion(from: session, timeout: .seconds(2))
        await session.stop()
        XCTAssertNotNil(completed, "подсказка должна сгенерироваться и без RAG")
        let called = await spy.topKWasCalled
        XCTAssertFalse(called, "в режиме низкой задержки topK не должен вызываться")
    }

    /// Троттлинг: три РАЗНЫХ партиала-вопроса подряд, быстрее cooldown → ровно ОДИН старт
    /// (иначе каждый дёрнутый ASR-партиал слал бы новый облачный запрос → упор в RPM).
    func testSpeculationThrottledAcrossRapidPartials() async {
        let session = makeSession(events: [
            event("как вы тестируете код?", isFinal: false),
            event("как вы тестируете код в проекте?", isFinal: false),
            event("как вы тестируете код в большом проекте?", isFinal: false),
        ], gap: .milliseconds(20), cooldown: .seconds(5))

        let detected = await countQuestionDetected(from: session, window: .milliseconds(600))
        XCTAssertEqual(detected, 1, "при cooldown спекуляция не должна перезапускаться на каждом партиале")
    }

    /// Без cooldown (`.zero`) троттлинг выключен — каждый изменившийся партиал-вопрос стартует.
    func testSpeculationNotThrottledWhenCooldownZero() async {
        let session = makeSession(events: [
            event("как вы тестируете код?", isFinal: false),
            event("как вы тестируете код в проекте?", isFinal: false),
            event("как вы тестируете код в большом проекте?", isFinal: false),
        ], gap: .milliseconds(20), cooldown: .zero)

        let detected = await countQuestionDetected(from: session, window: .milliseconds(600))
        XCTAssertEqual(detected, 3, "без cooldown каждый новый партиал-вопрос стартует ответ")
    }

    // MARK: - Helpers

    /// Считает события `.questionDetected` за окно — прямой индикатор числа стартов
    /// генерации (эмитится один раз на каждый startAnswer, до создания Task).
    private func countQuestionDetected(from session: SessionActor, window: Duration) async -> Int {
        let counter = Counter()
        let stream = await session.start()
        let consume = Task {
            for await ev in stream {
                if case .questionDetected = ev { await counter.increment() }
            }
        }
        try? await Task.sleep(for: window)
        await session.stop()
        consume.cancel()
        return await counter.value
    }

    /// Ждёт первую завершённую подсказку, гоняясь с РЕАЛЬНЫМ таймаутом (а не проверкой
    /// дедлайна по приходу события — иначе при затихшем потоке for-await парковался бы).
    private func firstSuggestion(from session: SessionActor, timeout: Duration) async -> Suggestion? {
        let stream = await session.start()
        return await withTaskGroup(of: Suggestion?.self) { group in
            group.addTask {
                for await event in stream {
                    if case .suggestionCompleted(let suggestion) = event { return suggestion }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// Потокобезопасный счётчик для тестов.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Движок расшифровки, выдающий заранее заданные события с паузой между ними
/// (игнорирует входное аудио) — для детерминированной проверки спекуляции.
private struct ScriptedTranscription: TranscriptionEngine {
    let events: [TranscriptEvent]
    let gap: Duration

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
        let events = self.events
        let gap = self.gap
        return AsyncStream { continuation in
            let task = Task {
                for event in events {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: gap)
                    continuation.yield(event)
                }
                // держим поток открытым, чтобы ветка не закрывалась раньше времени;
                // отмена при stop() завершит задачу.
                try? await Task.sleep(for: .seconds(10))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Контекст-шпион: фиксирует факт вызова topK (для проверки режима без RAG).
private actor SpyContext: ContextProviding {
    private(set) var topKWasCalled = false
    func warmUp() async {}
    func topK(for query: String, k: Int) async -> [ContextSnippet] {
        topKWasCalled = true
        return []
    }
}

private extension SessionConfiguration {
    /// Удобный билдер для теста: задать useContextRetrieval поверх инициализатора.
    func with(useContextRetrieval: Bool) -> SessionConfiguration {
        var copy = self
        copy.useContextRetrieval = useContextRetrieval
        return copy
    }
}
