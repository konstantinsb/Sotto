import Foundation

/// Оркестратор сессии. Сшивает конвейер целиком и публикует наружу единый поток
/// `SessionEvent`. Состояние изолировано актёром — никаких ручных блокировок и гонок.
///
/// Поток данных (в фазе 1 все движки — фейки, но проводка настоящая):
/// захват → расшифровка → (для собеседника) детектор вопроса → контекст →
/// сборка промпта → LLM → токены наружу в UI.
public actor SessionActor {

    /// Внедряемые зависимости — все движки за протоколами, легко подменяются.
    public struct Dependencies: Sendable {
        public var micCapture: any AudioCapturing
        public var systemCapture: any AudioCapturing
        public var micTranscription: any TranscriptionEngine
        public var systemTranscription: any TranscriptionEngine
        public var detector: any QuestionDetecting
        public var context: any ContextProviding
        public var llm: any LLMEngine
        public var promptBuilder: PromptBuilder
        /// Отладочная запись (WAV + лог расшифровки). nil — выключено.
        public var debugCapture: DebugCapture?

        public init(
            micCapture: any AudioCapturing,
            systemCapture: any AudioCapturing,
            micTranscription: any TranscriptionEngine,
            systemTranscription: any TranscriptionEngine,
            detector: any QuestionDetecting,
            context: any ContextProviding,
            llm: any LLMEngine,
            promptBuilder: PromptBuilder,
            debugCapture: DebugCapture? = nil
        ) {
            self.micCapture = micCapture
            self.systemCapture = systemCapture
            self.micTranscription = micTranscription
            self.systemTranscription = systemTranscription
            self.detector = detector
            self.context = context
            self.llm = llm
            self.promptBuilder = promptBuilder
            self.debugCapture = debugCapture
        }
    }

    private let configuration: SessionConfiguration
    private let deps: Dependencies
    private var tasks: [Task<Void, Never>] = []
    private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
    private var state: SessionState = .idle
    private var hasStarted = false
    /// Сколько генераций подсказок идёт прямо сейчас — индикатор возвращается из
    /// `.thinking` в `.listening` только когда обнулится (нет «залипания» при двух
    /// вопросах подряд, когда первая генерация завершилась, а вторая ещё идёт).
    private var inFlightAnswers = 0
    /// Нормализованный текст вопроса, по которому уже идёт СПЕКУЛЯТИВНЫЙ ответ (старт
    /// на частичной гипотезе). На финале сверяем с ним, чтобы не дублировать генерацию.
    private var speculatedNorm: String?
    /// Текущая спекулятивная задача — отменяется, когда вопрос изменился или финал
    /// разошёлся со спекуляцией.
    private var speculativeTask: Task<Void, Never>?
    /// Монотонные часы для троттлинга спекуляции (независимы от системного времени).
    private let speculationClock = ContinuousClock()
    /// Когда стартовала последняя спекуляция — чтобы не плодить облачные запросы чаще
    /// `speculationCooldown`. Сбрасывается на финале (новый вопрос стартует без задержки).
    private var lastSpeculationAt: ContinuousClock.Instant?

    public init(configuration: SessionConfiguration, dependencies: Dependencies) {
        self.configuration = configuration
        self.deps = dependencies
    }

    /// Запустить сессию. Возвращает поток событий для UI. Прогрев идёт в фоне.
    /// Идемпотентно: повторный вызов на одном инстансе не плодит второй конвейер
    /// (вернёт сразу завершённый поток).
    public func start() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        guard !hasStarted else {
            AppLog.session.error("SessionActor.start вызван повторно — игнорирую")
            continuation.finish()
            return stream
        }
        hasStarted = true
        eventContinuation = continuation
        setState(.warmingUp)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline()
        }
        tasks.append(task)
        return stream
    }

    /// Остановить сессию: отменить все задачи и завершить поток событий.
    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        setState(.idle)
        eventContinuation?.finish()
        eventContinuation = nil
        // Выгрузить модели и освободить память (важно на 16 ГБ при со-резидентности).
        let deps = self.deps
        Task {
            await deps.llm.unload()
            await deps.micTranscription.unload()
            await deps.systemTranscription.unload()
            await deps.context.unload()
            await deps.debugCapture?.finish()
        }
    }

    // MARK: - Конвейер

    private func runPipeline() async {
        // Системный канал (собеседник) — критический путь до первой подсказки: греем его,
        // LLM и контекст, сразу выходим в .listening и стартуем ветку. Загрузка модели
        // Whisper может скачивать веса при первом старте.
        do {
            try await deps.systemTranscription.warmUp()
        } catch {
            // Без расшифровки собеседника подсказок не будет — это фатально.
            emit(.failure("Не удалось загрузить модель расшифровки — \(error.localizedDescription)"))
            setState(.failed)
            return
        }
        await deps.llm.warmUp()
        await deps.context.warmUp()
        if Task.isCancelled { return }
        setState(.listening)
        startBranch(capture: deps.systemCapture, engine: deps.systemTranscription, detectQuestions: true)
        // Микрофон кандидата — опциональный второй канал (полный транскрипт диалога).
        // Прогрев + старт в фоне, ПОСЛЕ выхода в .listening: загрузка второй ASR-модели не
        // задерживает подсказки по собеседнику; провал прогрева гасит только этот канал.
        // Вопросы ищем только у собеседника (для микрофона detectQuestions: false).
        startBranch(capture: deps.micCapture, engine: deps.micTranscription, detectQuestions: false, warmUpFirst: true)
    }

    private func startBranch(
        capture: any AudioCapturing,
        engine: any TranscriptionEngine,
        detectQuestions: Bool,
        warmUpFirst: Bool = false
    ) {
        let recorder = deps.debugCapture
        let task = Task { [weak self] in
            // Опциональный канал (микрофон) греет свою модель в этой же задаче: загрузка не
            // блокирует критический путь, а отмена сессии отменяет и прогрев. Провал —
            // не-фатальный (гаснет только микрофон), как было у фейкового движка.
            if warmUpFirst {
                do { try await engine.warmUp() }
                catch {
                    // Прогрев мог упасть из-за отмены (стоп сессии во время загрузки) — тогда
                    // не эмитим ошибку в (уже закрывающийся) поток, чтобы не мигнуть ложным сбоем.
                    if !Task.isCancelled {
                        await self?.emit(.failure("Микрофон: не удалось загрузить модель расшифровки — \(error.localizedDescription)"))
                    }
                    return
                }
                if Task.isCancelled { return }
            }
            // Отладочная запись пишет ВСЁ аудио (до drop-to-live), а движок получает
            // ограниченную очередь: при отставании старые чанки выбрасываются, чтобы
            // подсказка шла по «сейчас», а не по аудио минутной давности.
            let audio = AudioBackpressure.dropToLive(Self.tee(capture.stream(), into: recorder))
            let events = engine.transcribe(audio)
            for await event in events {
                if Task.isCancelled { break }
                await self?.handle(event, detectQuestions: detectQuestions)
            }
        }
        tasks.append(task)
    }

    /// Прокладка: дублирует аудио в отладочную запись (если включена), не меняя поток к движку.
    private static func tee(_ source: AsyncStream<AudioChunk>, into recorder: DebugCapture?) -> AsyncStream<AudioChunk> {
        guard let recorder else { return source }
        return AsyncStream { continuation in
            let task = Task {
                for await chunk in source {
                    await recorder.appendAudio(chunk.samples, source: chunk.source, sampleRate: chunk.sampleRate)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func handle(_ event: TranscriptEvent, detectQuestions: Bool) async {
        emit(.transcript(event))
        await deps.debugCapture?.logTranscript(event)
        guard detectQuestions else { return }

        switch event {
        case .partial(let segment):
            // Спекулятивный старт: частичная гипотеза уже выглядит завершённым вопросом
            // (последнее предложение с «?»). Убирает ожидание финала (~0.8–1.3 c тишины).
            guard configuration.speculateOnPartials,
                  let question = deps.detector.detectSpeculative(in: segment) else { return }
            let norm = Self.normalize(question.question)
            guard norm != speculatedNorm else { return }   // этот вопрос уже спекулируем
            // Троттлинг: ASR дёргает текст/пунктуацию каждые ~0.4 c, и без ограничения каждый
            // партиал слал бы новый облачный запрос → упор в RPM провайдера. Пропускаем повтор,
            // если с прошлой спекуляции прошло меньше cooldown (финал всё равно догенерит).
            if configuration.speculationCooldown > .zero,
               let last = lastSpeculationAt,
               last.duration(to: speculationClock.now) < configuration.speculationCooldown {
                return
            }
            // Известный узкий edge: если один и тот же вопрос «дорастает» (ASR вставил «?»
            // рано, затем досказал) и РАННЯЯ спекуляция успела завершиться до нового партиала,
            // в истории может остаться лишняя подсказка. Практически редко: ответ LLM длиннее
            // паузы между партиалами, поэтому ранняя спекуляция почти всегда ещё идёт и
            // отменяется здесь (startAnswer → speculativeTask.cancel) до завершения.
            speculatedNorm = norm
            lastSpeculationAt = speculationClock.now
            await deps.debugCapture?.logQuestion(question.question)
            startAnswer(question, speculative: true)

        case .final(let segment):
            guard let question = deps.detector.detect(in: segment) else { return }
            let norm = Self.normalize(question.question)
            // Финал совпал с уже идущей спекуляцией — не дублируем, ответ остаётся.
            if let pending = speculatedNorm, Self.closeEnough(pending, norm) {
                speculatedNorm = nil
                speculativeTask = nil   // пусть спекулятивный ответ доживёт (он верный)
                lastSpeculationAt = nil // следующий вопрос спекулирует без задержки
                return
            }
            speculatedNorm = nil
            lastSpeculationAt = nil     // следующий вопрос спекулирует без задержки
            await deps.debugCapture?.logQuestion(question.question)
            startAnswer(question, speculative: false)
        }
    }

    /// Запустить генерацию ответа. Любой новый запуск отменяет предыдущую спекуляцию
    /// (вопрос вырос/изменился, или финал разошёлся со спекуляцией) — чтобы не висел
    /// устаревший/неверный ответ и не плодились параллельные генерации одного вопроса.
    private func startAnswer(_ question: DetectedQuestion, speculative: Bool) {
        speculativeTask?.cancel()
        speculativeTask = nil
        emit(.questionDetected(question))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.answer(question)
        }
        if speculative { speculativeTask = task }
        tasks.append(task)
    }

    /// Ответ на детектированный вопрос собеседника — тонкая обёртка над общим ядром
    /// генерации (без экрана; триггер — сегмент расшифровки).
    private func answer(_ question: DetectedQuestion) async {
        await runGeneration(question: question.question, screenText: nil, triggeringSegmentID: question.segment.id)
    }

    /// Ручной разбор экрана через ГОЛОСОВОЙ тракт во время активной сессии: один ответ
    /// «код на экране + последний устный вопрос» в той же карте, что и обычные подсказки
    /// (эмит в общий поток событий). При пустом/пробельном вопросе подставляем дефолтную
    /// русскую инструкцию, чтобы модель разобрала именно код. RAG пропускаем, если исходный
    /// вопрос пуст (искать по дефолтной инструкции бессмысленно).
    public func solveScreen(question: String, screenText: String) {
        // Отменяем текущую спекуляцию (как в startAnswer): новый ручной запрос важнее
        // висящего спекулятивного ответа на устаревшем вопросе. Зеркалим бухгалтерию из
        // handle(финал): без сброса speculatedNorm пришедший позже финал того же устного
        // вопроса попал бы в ветку closeEnough и был бы молча проглочен (без ответа).
        speculativeTask?.cancel()
        speculativeTask = nil
        speculatedNorm = nil
        lastSpeculationAt = nil

        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveQuestion = trimmed.isEmpty
            ? "Разбери код на экране: что это и что с ним делать."
            : trimmed
        // RAG имеет смысл только по реальному устному вопросу; при дефолтной инструкции — нет.
        let skipRetrieval = trimmed.isEmpty

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runGeneration(
                question: effectiveQuestion,
                screenText: screenText,
                triggeringSegmentID: nil,
                skipRetrieval: skipRetrieval
            )
        }
        tasks.append(task)
    }

    /// Ядро генерации одной подсказки: индикатор `.thinking`, открытие потока подсказки,
    /// опц. RAG, сборка промпта (с экраном или без), стрим LLM и финал (`suggestionCompleted`
    /// или `failure`). Эмитит в общий поток сессии — карта всегда одна.
    ///
    /// - Parameters:
    ///   - question: вопрос для промпта (уже эффективный — с подставленной инструкцией при разборе экрана).
    ///   - screenText: OCR-текст экрана или nil (для обычной голосовой подсказки).
    ///   - triggeringSegmentID: сегмент-триггер для `Suggestion` (nil для ручного разбора экрана).
    ///   - skipRetrieval: жёстко пропустить RAG (ручной разбор экрана без устного вопроса).
    private func runGeneration(
        question: String,
        screenText: String?,
        triggeringSegmentID: UUID?,
        skipRetrieval: Bool = false
    ) async {
        inFlightAnswers += 1
        if state != .thinking { setState(.thinking) }
        defer {
            inFlightAnswers -= 1
            if inFlightAnswers == 0, state == .thinking { setState(.listening) }
        }

        // Сразу открываем поток подсказки: клиент сбрасывает живой пузырь по этому id, и
        // устаревший спекулятивный партиал не «мигает», пока идёт RAG/префилл (#3).
        let id = UUID()
        emit(.suggestionStarted(id: id))

        // Режим низкой задержки: пропускаем эмбеддинг запроса + поиск, опираясь на
        // уже вшитый profileSummary — убирает RAG с критического пути до первого токена.
        // skipRetrieval жёстко выключает поиск (ручной разбор экрана без устного вопроса).
        let snippets = (configuration.useContextRetrieval && !skipRetrieval)
            ? await deps.context.topK(for: question, k: configuration.topK)
            : []
        if Task.isCancelled { return }
        let prompt = deps.promptBuilder.build(
            mode: configuration.mode,
            systemPrompt: configuration.systemPrompt,
            profileSummary: configuration.profileSummary,
            context: snippets,
            question: question,
            screenText: screenText
        )

        let clock = ContinuousClock()
        let begin = clock.now
        var firstTokenMs: Int?
        var assembled = ""
        var genError: Error?

        do {
            for try await token in deps.llm.generate(prompt: prompt, options: configuration.generationOptions) {
                if Task.isCancelled { break }
                if firstTokenMs == nil {
                    firstTokenMs = begin.duration(to: clock.now).milliseconds
                }
                assembled += token
                emit(.suggestionToken(id: id, token: token))
            }
        } catch {
            genError = error
        }

        // После остановки не эмитим хвостовые события в (возможно) завершённый поток.
        if Task.isCancelled { return }

        let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // Пустой ответ = сбой генерации — теперь с внятной причиной, если движок
            // пробросил ошибку (раньше она проглатывалась и оставался пустой пузырь).
            let detail = genError.map { " — \($0.localizedDescription)" } ?? ""
            emit(.failure("Не удалось сгенерировать подсказку\(detail)"))
        } else {
            let suggestion = Suggestion(
                id: id,
                triggeringSegmentID: triggeringSegmentID,
                text: text,
                model: deps.llm.modelName,
                latencyMs: firstTokenMs,
                createdAt: Date().timeIntervalSince1970
            )
            emit(.suggestionCompleted(suggestion))
            await deps.debugCapture?.logSuggestion(text, latencyMs: firstTokenMs)
        }
    }

    // MARK: - Вспомогательное

    /// Нормализация для сверки вопросов: нижний регистр, только буквы/цифры, схлопнутые
    /// пробелы (пунктуация и регистр не должны мешать сопоставлению спекуляции с финалом).
    static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Спекуляция и финал — «тот же вопрос», если нормализованные тексты совпадают или
    /// один является префиксом другого и при этом покрывает ≥60% длины (частичная гипотеза
    /// обычно короче финала). Порог отсекает совпадение по короткому общему началу.
    static func closeEnough(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard longer.hasPrefix(shorter) else { return false }
        return Double(shorter.count) >= 0.6 * Double(longer.count)
    }

    private func setState(_ newState: SessionState) {
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: SessionEvent) {
        eventContinuation?.yield(event)
    }
}

private extension Duration {
    /// Перевод длительности в миллисекунды.
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
