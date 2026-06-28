import XCTest
@testable import SottoCore

final class SessionActorTests: XCTestCase {

    /// Сквозной прогон конвейера на фейках: вопрос собеседника должен привести
    /// к детекту и к завершённой подсказке с непустым текстом.
    func testFakePipelineProducesSuggestion() async {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 60),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 60),
            micTranscription: FakeTranscriptionEngine(source: .microphone, script: ["я думаю"], chunksPerWord: 1),
            systemTranscription: FakeTranscriptionEngine(source: .system, script: ["как вы решаете гонки данных?"], chunksPerWord: 1),
            detector: HeuristicQuestionDetector(),
            context: FakeContextEngine(),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1), answer: "через actor изоляцию"),
            promptBuilder: PromptBuilder()
        )
        let session = SessionActor(
            configuration: SessionConfiguration(
                mode: .iosInterview,
                systemPrompt: SystemPrompts.text(for: .iosInterview),
                profileSummary: "iOS, 5 лет"
            ),
            dependencies: deps
        )

        var sawQuestion = false
        var sawPartial = false
        var completed: Suggestion?

        let stream = await session.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        for await event in stream {
            switch event {
            case .transcript(.partial): sawPartial = true
            case .questionDetected: sawQuestion = true
            case .suggestionCompleted(let suggestion): completed = suggestion
            default: break
            }
            if completed != nil { break }
            if ContinuousClock().now > deadline { break }
        }
        await session.stop()

        XCTAssertTrue(sawPartial, "ожидались частичные гипотезы расшифровки")
        XCTAssertTrue(sawQuestion, "вопрос собеседника должен быть обнаружен")
        let suggestion = try? XCTUnwrap(completed)
        XCTAssertFalse(suggestion?.text.isEmpty ?? true, "подсказка должна быть непустой")
        XCTAssertEqual(suggestion?.model, "fake-llm")
    }

    /// Провал прогрева расшифровки должен эмитить .failure, но НЕ быть фатальным —
    /// сессия продолжает работу и доходит до .listening.
    func testWarmUpFailureEmitsFailureButContinues() async {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 20),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 20),
            micTranscription: ThrowingWarmUpTranscription(),
            systemTranscription: FakeTranscriptionEngine(source: .system, script: ["привет"], chunksPerWord: 1),
            detector: HeuristicQuestionDetector(),
            context: FakeContextEngine(),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1)),
            promptBuilder: PromptBuilder()
        )
        let session = SessionActor(
            configuration: SessionConfiguration(mode: .iosInterview, systemPrompt: "s"),
            dependencies: deps
        )

        var sawFailure = false
        var sawListening = false
        let stream = await session.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            switch event {
            case .failure: sawFailure = true
            case .stateChanged(.listening): sawListening = true
            default: break
            }
            if sawFailure && sawListening { break }
            if ContinuousClock().now > deadline { break }
        }
        await session.stop()

        XCTAssertTrue(sawFailure, "провал прогрева должен эмитить .failure")
        XCTAssertTrue(sawListening, "сессия должна продолжить в .listening (провал не фатален)")
    }

    /// Сбой прогрева расшифровки СОБЕСЕДНИКА фатален → терминальное .failed (не «залипает»).
    func testSystemWarmUpFailureIsFatal() async {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 10),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 10),
            micTranscription: FakeTranscriptionEngine(source: .microphone, script: []),
            systemTranscription: ThrowingWarmUpTranscription(),
            detector: HeuristicQuestionDetector(),
            context: FakeContextEngine(),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1)),
            promptBuilder: PromptBuilder()
        )
        let session = SessionActor(
            configuration: SessionConfiguration(mode: .iosInterview, systemPrompt: "s"),
            dependencies: deps
        )

        var sawFailed = false
        var sawListening = false
        let stream = await session.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            switch event {
            case .stateChanged(.failed): sawFailed = true
            case .stateChanged(.listening): sawListening = true
            default: break
            }
            if sawFailed { break }
            if ContinuousClock().now > deadline { break }
        }
        await session.stop()

        XCTAssertTrue(sawFailed, "сбой системной расшифровки должен переводить в .failed")
        XCTAssertFalse(sawListening, "не должны доходить до .listening при фатальном сбое")
    }

    /// Сбой генерации (поток LLM бросает ошибку) должен дать .failure с причиной,
    /// а не молчаливый пустой пузырь подсказки.
    func testLLMGenerationErrorEmitsFailureWithDetail() async {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 60),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 60),
            micTranscription: FakeTranscriptionEngine(source: .microphone, script: []),
            systemTranscription: FakeTranscriptionEngine(source: .system, script: ["как вы решаете гонки данных?"], chunksPerWord: 1),
            detector: HeuristicQuestionDetector(),
            context: FakeContextEngine(),
            llm: ThrowingLLMEngine(),
            promptBuilder: PromptBuilder()
        )
        let session = SessionActor(
            configuration: SessionConfiguration(mode: .iosInterview, systemPrompt: "s"),
            dependencies: deps
        )

        var failureMessage: String?
        let stream = await session.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            if case .failure(let message) = event { failureMessage = message; break }
            if ContinuousClock().now > deadline { break }
        }
        await session.stop()

        let message = try? XCTUnwrap(failureMessage)
        XCTAssertTrue(message?.contains("Не удалось сгенерировать подсказку") ?? false)
        XCTAssertTrue(message?.contains(ThrowingLLMEngine.detail) ?? false,
                      "сообщение должно включать причину ошибки от движка")
    }

    /// Свой голос (канал микрофона) расшифровывается и доходит до UI, но НЕ триггерит
    /// подсказки: вопросо-образная фраза на микрофоне не должна давать ни .questionDetected,
    /// ни подсказку (detectQuestions: false). Гарантия активна с подключением реального
    /// микрофона — раньше канал был немым фейком и это не проверялось.
    func testMicrophoneTranscriptFlowsButDoesNotTriggerAnswers() async {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 60),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 60),
            // На МИКРОФОНЕ — вопросо-образная фраза (с «?»); на собеседнике — утверждение.
            micTranscription: FakeTranscriptionEngine(source: .microphone, script: ["а как насчёт гонок данных?"], chunksPerWord: 1),
            systemTranscription: FakeTranscriptionEngine(source: .system, script: ["понятно спасибо"], chunksPerWord: 1),
            detector: HeuristicQuestionDetector(),
            context: FakeContextEngine(),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1), answer: "ответ"),
            promptBuilder: PromptBuilder()
        )
        let session = SessionActor(
            configuration: SessionConfiguration(mode: .iosInterview, systemPrompt: "s"),
            dependencies: deps
        )

        var sawMicFinal = false
        var sawSystemFinal = false
        var sawQuestion = false
        var sawSuggestion = false
        let stream = await session.start()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            switch event {
            case .transcript(.final(let segment)):
                if segment.source == .microphone { sawMicFinal = true }
                if segment.source == .system { sawSystemFinal = true }
            case .questionDetected: sawQuestion = true
            case .suggestionCompleted: sawSuggestion = true
            default: break
            }
            // Оба канала отработали свои скрипты → детект (если бы был) уже эмитнут.
            if sawMicFinal && sawSystemFinal { break }
            if ContinuousClock().now > deadline { break }
        }
        await session.stop()

        XCTAssertTrue(sawMicFinal, "финал расшифровки микрофона должен доходить до UI")
        XCTAssertFalse(sawQuestion, "вопрос на канале микрофона НЕ должен детектиться")
        XCTAssertFalse(sawSuggestion, "свой голос не должен триггерить подсказку")
    }

    // MARK: - solveScreen (разбор экрана через голосовой тракт)

    /// Собирает сессию, где оба канала молчат (нет детекта вопросов) — единственная
    /// подсказка приходит от ручного `solveScreen`.
    private func makeSilentSession(answer: String) -> SessionActor {
        let deps = SessionActor.Dependencies(
            micCapture: FakeAudioCapture(source: .microphone, interval: .milliseconds(1), finishAfter: 400),
            systemCapture: FakeAudioCapture(source: .system, interval: .milliseconds(1), finishAfter: 400),
            micTranscription: FakeTranscriptionEngine(source: .microphone, script: []),
            systemTranscription: FakeTranscriptionEngine(source: .system, script: []),
            detector: HeuristicQuestionDetector(),
            context: FakeContextEngine(),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1), answer: answer),
            promptBuilder: PromptBuilder()
        )
        return SessionActor(
            configuration: SessionConfiguration(mode: .iosInterview, systemPrompt: "s"),
            dependencies: deps
        )
    }

    /// Ручной разбор экрана эмитит suggestionStarted + токены + suggestionCompleted
    /// в общий поток событий сессии (та же карта, что и обычные подсказки).
    func testSolveScreenEmitsSuggestionInSessionStream() async {
        let session = makeSilentSession(answer: "это two sum за O(n) через словарь")

        var sawStarted = false
        var sawToken = false
        var completed: Suggestion?

        let stream = await session.start()
        // Ручной разбор дёргаем из отдельной задачи (трогает только Sendable-актор),
        // а сам поток событий потребляем инлайн — как в остальных тестах файла,
        // чтобы не ловить гонку по локальным переменным под строгой конкуренцией.
        let trigger = Task {
            try? await Task.sleep(for: .milliseconds(50))
            await session.solveScreen(question: "Что это за код?", screenText: "func twoSum(_ nums: [Int]) -> [Int]")
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            switch event {
            case .suggestionStarted: sawStarted = true
            case .suggestionToken: sawToken = true
            case .suggestionCompleted(let s): completed = s
            default: break
            }
            if completed != nil { break }
            if ContinuousClock().now > deadline { break }
        }
        trigger.cancel()
        await session.stop()

        XCTAssertTrue(sawStarted, "ожидался suggestionStarted")
        XCTAssertTrue(sawToken, "ожидались токены подсказки")
        let suggestion = try? XCTUnwrap(completed)
        XCTAssertFalse(suggestion?.text.isEmpty ?? true, "подсказка от разбора экрана должна быть непустой")
        XCTAssertNil(suggestion?.triggeringSegmentID, "у ручного разбора экрана нет триггер-сегмента")
    }

    /// Пустой устный вопрос + непустой экран всё равно даёт непустой ответ (срабатывает
    /// дефолтная русская инструкция «Разбери код на экране…»).
    func testSolveScreenWithEmptyQuestionStillAnswers() async {
        let session = makeSilentSession(answer: "разбор кода с экрана")

        var completed: Suggestion?
        let stream = await session.start()
        // Триггер — отдельной задачей; поток потребляем инлайн (без гонки по локалям).
        let trigger = Task {
            try? await Task.sleep(for: .milliseconds(50))
            await session.solveScreen(question: "   ", screenText: "let arr = [3, 1, 2].sorted()")
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            if case .suggestionCompleted(let s) = event { completed = s; break }
            if ContinuousClock().now > deadline { break }
        }
        trigger.cancel()
        await session.stop()

        let suggestion = try? XCTUnwrap(completed)
        XCTAssertFalse(suggestion?.text.isEmpty ?? true,
                       "пустой вопрос + экран должен дать непустой ответ по дефолтной инструкции")
    }
}

/// Фейк расшифровки, падающий на прогреве (для теста не-фатального провала warmUp).
private struct ThrowingWarmUpTranscription: TranscriptionEngine {
    struct WarmUpError: Error {}
    func warmUp() async throws { throw WarmUpError() }
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
        AsyncStream { $0.finish() }
    }
}

/// Фейк LLM, чей поток генерации бросает ошибку (для теста канала ошибок).
private struct ThrowingLLMEngine: LLMEngine {
    static let detail = "движок упал"
    struct GenError: LocalizedError { var errorDescription: String? { ThrowingLLMEngine.detail } }
    let modelName = "throwing-llm"
    func warmUp() async {}
    func generate(prompt: Prompt, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: GenError()) }
    }
}
