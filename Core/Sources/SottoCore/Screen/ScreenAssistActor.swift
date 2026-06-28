import Foundation

/// Оркестратор разбора экрана: захват + OCR → промпт → LLM (поток токенов).
/// Поток данных по образцу `SessionActor`: наружу — единый `AsyncStream<ScreenAssistEvent>`,
/// состояние изолировано актёром.
///
/// LLM прогревается лениво и удерживается в памяти между вызовами (первый разбор грузит
/// модель, последующие — быстрые). Один разбор за раз: повторный `solve()`, пока идёт
/// текущий, возвращает сразу завершённый поток.
public actor ScreenAssistActor {
    private let source: any ScreenTextSource
    private let llm: any LLMEngine
    private let promptBuilder: CodeAssistPromptBuilder
    private let options: GenerationOptions

    private var warmed = false
    private var currentTask: Task<Void, Never>?

    public init(
        source: any ScreenTextSource,
        llm: any LLMEngine,
        promptBuilder: CodeAssistPromptBuilder = CodeAssistPromptBuilder(),
        options: GenerationOptions = .screenAssist
    ) {
        self.source = source
        self.llm = llm
        self.promptBuilder = promptBuilder
        self.options = options
    }

    /// Прогреть LLM заранее (по желанию — чтобы первый разбор был быстрым).
    public func warmUp() async {
        guard !warmed else { return }
        await llm.warmUp()
        warmed = true
    }

    /// Выгрузить модель и освободить память.
    public func unload() async {
        currentTask?.cancel()
        currentTask = nil
        await llm.unload()
        warmed = false
    }

    /// Разобрать текущий экран. Возвращает поток событий для UI.
    /// Вопрос интервьюера, профиль и выбранная область меняются к каждому хоткею, поэтому
    /// приходят на каждый запуск (а не вшиты в конструктор). `region == nil` — весь дисплей.
    public func solve(
        question: String = "",
        profileSummary: String = "",
        region: CaptureRegion? = nil
    ) -> AsyncStream<ScreenAssistEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScreenAssistEvent.self)
        guard currentTask == nil else {
            continuation.finish()
            return stream
        }
        currentTask = Task { [weak self] in
            await self?.run(continuation, question: question, profileSummary: profileSummary, region: region)
        }
        return stream
    }

    /// Отменить текущий разбор.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Только захват экрана + OCR (без прогрева LLM и без генерации). Нужен App-слою,
    /// чтобы получить текст экрана и отдать его в голосовой тракт сессии
    /// (`SessionActor.solveScreen`) — единый ответ «код + устный вопрос» в одной карте.
    public func captureText(region: CaptureRegion? = nil) async throws -> String {
        try await source.recognizeScreenText(region: region).text
    }

    private func run(
        _ continuation: AsyncStream<ScreenAssistEvent>.Continuation,
        question: String,
        profileSummary: String,
        region: CaptureRegion?
    ) async {
        defer {
            currentTask = nil
            continuation.finish()
        }

        // 1. Захват экрана + OCR.
        continuation.yield(.stateChanged(.capturing))
        let recognized: RecognizedScreen
        do {
            recognized = try await source.recognizeScreenText(region: region)
        } catch {
            continuation.yield(.failure("Не удалось прочитать экран — \(error.localizedDescription)"))
            continuation.yield(.stateChanged(.failed))
            return
        }
        if Task.isCancelled { return }
        guard !recognized.isEmpty else {
            continuation.yield(.failure("На экране не найдено текста для разбора"))
            continuation.yield(.stateChanged(.failed))
            return
        }
        continuation.yield(.recognizedText(recognized.text))

        // 2. Прогрев модели (один раз) — может скачивать веса при первом запуске.
        if !warmed {
            await llm.warmUp()
            warmed = true
        }
        if Task.isCancelled { return }

        // 3. Генерация решения потоком.
        continuation.yield(.stateChanged(.thinking))
        let prompt = promptBuilder.build(
            screenText: recognized.text,
            profileSummary: profileSummary,
            spokenQuestion: question
        )
        continuation.yield(.solutionStarted)

        var assembled = ""
        var genError: Error?
        do {
            for try await token in llm.generate(prompt: prompt, options: options) {
                if Task.isCancelled { break }
                assembled += token
                continuation.yield(.solutionToken(token))
            }
        } catch {
            genError = error
        }
        if Task.isCancelled { return }

        let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let detail = genError.map { " — \($0.localizedDescription)" } ?? ""
            continuation.yield(.failure("Не удалось сгенерировать решение\(detail)"))
            continuation.yield(.stateChanged(.failed))
        } else {
            continuation.yield(.solutionCompleted(text))
            continuation.yield(.stateChanged(.done))
        }
    }
}
