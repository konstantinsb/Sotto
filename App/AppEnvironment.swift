import Foundation
import Observation
import SottoCore
import SottoWhisper
import SottoParakeet
import SottoMLX

/// Корень композиции и мост между оркестратором и UI.
/// Живёт на главном актёре: собирает зависимости по выбору моделей, запускает
/// `SessionActor`, потребляет поток `SessionEvent` и проецирует его в наблюдаемое
/// состояние `ConversationState` (логика проекции вынесена в тестируемый Core-тип).
@MainActor
@Observable
final class AppEnvironment {
    // maxFinals с запасом под ДВА активных канала (собеседник + микрофон): при общем лимите
    // более частые финалы своего голоса вытесняли бы реплики собеседника из записи/истории.
    private(set) var conversation = ConversationState(maxFinals: 200)
    private(set) var isRunning = false

    // Прогресс скачивания моделей, nil — не качаем.
    private(set) var downloadProgress: DownloadProgress?
    private(set) var downloadLabel: String = ""

    // Тест микрофона (Фаза 2)
    private(set) var micTestRunning = false
    private(set) var micPermissionDenied = false
    private(set) var micRMS: Float = 0
    private(set) var micChunkCount = 0
    private(set) var micSpeechRatio: Double = 0
    private(set) var micDroppedBlocks = 0

    // Выбор моделей
    let registry = ModelRegistry.default
    let device = DeviceCapabilities.current()
    private(set) var selection: ModelSelection
    private(set) var library: ProfileLibrary
    private(set) var selectedMode: ModeKind

    /// Профиль активного контекста — идёт в подсказки и разбор экрана.
    var activeProfile: UserProfile { library.activeProfile }

    // Summary разговора
    private(set) var summaryText = ""
    private(set) var summaryRunning = false

    // Разбор экрана (OCR + LLM) по глобальному хоткею ⌥⌘S
    private(set) var screenAssist = ScreenAssistState()

    // Идёт захват экрана для голосового тракта активной сессии (⌥⌘S во время сессии).
    // НАБЛЮДАЕМОЕ (не @ObservationIgnored): UI читает его, чтобы подсветить/заблокировать
    // кнопку разбора, пока screenAssist.phase ещё .idle (ответ уйдёт в insightCard сессии).
    private(set) var screenAnalyzing = false

    // Отладочная запись (WAV входного аудио + лог расшифровки) для оценки качества
    private(set) var debugCaptureEnabled: Bool = false
    /// Держать оверлей поверх ВСЕХ окон (вкл. фуллскрин). По умолчанию выкл — вежливый
    /// уровень .floating (над окном звонка, но не над фуллскрином). Настройка в Settings.
    private(set) var overlayAlwaysOnTop: Bool = false
    private(set) var lastDebugFolder: URL?
    // Итог авто-оценки качества расшифровки последней сессии (эталон vs живая)
    private(set) var lastEvalSummary: String?

    // Облако (режим точности): opt-in подмена локального LLM на Claude (Anthropic API).
    // ASR и RAG остаются локальными — в облако уходит только генерация ответа.
    private(set) var cloudEnabled: Bool = false
    private(set) var cloudProvider: CloudProvider = .default
    private(set) var cloudModel: String = CloudProvider.default.defaultModel
    private(set) var cloudAPIKey: String = ""

    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let profileStore = ProfileStore()
    @ObservationIgnored private var session: SessionActor?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var floatingController: FloatingPanelController?
    @ObservationIgnored private var micTask: Task<Void, Never>?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var evalTask: Task<Void, Never>?
    @ObservationIgnored private var screenAssistActor: ScreenAssistActor?
    @ObservationIgnored private var screenAssistTask: Task<Void, Never>?
    /// Стелс-выбор области экрана (как Cmd+Shift+4) — показывается на ⌥⌘S перед захватом.
    @ObservationIgnored private let regionSelector = RegionSelectionController()
    @ObservationIgnored private var screenHotkey: GlobalHotkey?
    @ObservationIgnored private var overlayHotkey: GlobalHotkey?
    // A8: один резидентный LLM-движок на summary и разбор экрана (а не пере-создание +
    // выгрузка на каждый вызов — это был худший путь по задержке). Живая сессия держит
    // свой движок отдельно: его жизненный цикл привязан к старту/стопу сессии.
    // A8: резидентный движок может быть локальным (MLX) или облачным (Anthropic) —
    // держим за протоколом; identity ("mlx:<repo>" / "cloud:<model>") решает, пересоздавать ли.
    @ObservationIgnored private var assistLLM: (any LLMEngine)?
    @ObservationIgnored private var assistLLMIdentity: String?
    @ObservationIgnored let sessionStore = SessionStore()
    // Время старта текущей сессии — для таймера в оверлее. @ObservationIgnored: меняется
    // синхронно на старте, до того как наблюдаемый isRunning перерисует View (которое и
    // прочитает свежее значение), поэтому отдельного наблюдения не требует.
    @ObservationIgnored private(set) var sessionStartedAt = Date()
    @ObservationIgnored private var isLiveSession = false

    init() {
        // A4: на первом запуске (нет сохранённого выбора) подбираем LLM под память
        // устройства — на слабом железе меньше и быстрее. Явный выбор не трогаем.
        selection = settingsStore
            .loadSelection(default: .recommended(for: DeviceCapabilities.current(), registry: ModelRegistry.default))
            .validated(against: ModelRegistry.default)
        library = profileStore.loadLibrary()
        selectedMode = settingsStore.loadMode()
        debugCaptureEnabled = settingsStore.loadDebugCapture()
        overlayAlwaysOnTop = settingsStore.loadOverlayAlwaysOnTop()
        cloudEnabled = settingsStore.loadCloudEnabled()
        cloudProvider = settingsStore.loadCloudProvider()
        cloudModel = settingsStore.loadCloudModel()
        cloudAPIKey = CloudCredentialStore.loadAPIKey(account: cloudProvider.keychainAccount)
        // Перенос моделей из прежних каталогов — ДО любых загрузок (вместо перекачки).
        ModelManager.migrateLegacyModels()
        registerGlobalHotkeys()
        // Оверлей НЕ показываем при запуске — он появляется по старту сессии (startLive) или по
        // разбору экрана (⌥⌘S). Так панель не висит на экране, пока встреча не началась.
    }

    func setDebugCapture(_ enabled: Bool) {
        debugCaptureEnabled = enabled
        settingsStore.saveDebugCapture(enabled)
    }

    /// Переключить «оверлей поверх всех окон». Сохраняем и применяем на лету к открытой панели.
    func setOverlayAlwaysOnTop(_ enabled: Bool) {
        overlayAlwaysOnTop = enabled
        settingsStore.saveOverlayAlwaysOnTop(enabled)
        floatingController?.setAlwaysOnTop(enabled)
    }

    /// Авто-оценка качества расшифровки после сессии: эталонная расшифровка записи
    /// (целый файл одним проходом) против живой потоковой, что использовалась в подсказках.
    /// Результат — `evaluation.txt`/`.json` в папке записи + краткий итог в меню.
    private func runPostSessionEvaluation() {
        guard debugCaptureEnabled, let folder = lastDebugFolder else { return }
        let wavURL = folder.appending(path: "system.wav")
        // Только системный канал: эталон ниже — перетранскрипция system.wav (звук
        // собеседника). Финалы микрофона сюда мешать нельзя — сравнение стало бы
        // некорректным (микрофон пишется в отдельный microphone.wav, своя WER — вне scope).
        let liveText = conversation.finals
            .filter { $0.source == .system }
            .map(\.text)
            .joined(separator: " ")
        let asr = registry.info(id: selection.asrModelID, kind: .asr) ?? registry.asr[0]
        lastEvalSummary = "оценка расшифровки…"
        evalTask?.cancel()
        evalTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))   // дать записи закрыться
            guard let samples = TranscriptionEvaluator.readWavSamples(wavURL), !samples.isEmpty else {
                self.lastEvalSummary = "оценка: запись пуста"
                return
            }
            // Эталон считаем тем же движком, что выбран (Parakeet/WhisperKit).
            let engine = self.makeASREngine(asr, onProgress: { _ in })
            let reference = (try? await engine.transcribeWhole(samples)) ?? ""
            await engine.unload()
            let eval = TranscriptionEvaluator.evaluate(referenceText: reference, liveText: liveText)
            TranscriptionEvaluator.writeReport(eval, to: folder)
            // Показываем выживаемость терминов как главную метрику (§8: WER вводит в заблуждение).
            self.lastEvalSummary = "расшифровка ≈\(eval.accuracyPercent)% · термины \(eval.terms.survivalPercent)% (\(eval.terms.survivedInLive)/\(eval.terms.termsInReference))"
        }
    }

    /// Отладочная запись текущей живой сессии (если включена в настройках).
    private func makeDebugCapture() -> DebugCapture? {
        guard debugCaptureEnabled else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let capture = DebugCapture(
            baseDirectory: ModelManager.debugDirectory,
            startedAt: sessionStartedAt,
            folderName: formatter.string(from: sessionStartedAt)
        )
        lastDebugFolder = capture?.directory
        return capture
    }

    func updateSelection(_ newValue: ModelSelection) {
        let previousLLM = selection.llmModelID
        selection = newValue.validated(against: registry)
        settingsStore.saveSelection(selection)
        // A8: сменилась LLM — выгружаем общий движок и сбрасываем актёр экрана, чтобы они
        // пересоздались на новой модели (иначе остался бы резидентным движок старой модели).
        if selection.llmModelID != previousLLM {
            resetAssistEngineForSourceChange()
        }
    }

    // MARK: - Облако (режим точности)

    func setCloudEnabled(_ enabled: Bool) {
        cloudEnabled = enabled
        settingsStore.saveCloudEnabled(enabled)
        resetAssistEngineForSourceChange()
    }

    func setCloudProvider(_ provider: CloudProvider) {
        guard provider != cloudProvider else { return }
        cloudProvider = provider
        settingsStore.saveCloudProvider(provider)
        // Модель — дефолт нового провайдера; ключ — из его ячейки Keychain (раздельно).
        cloudModel = provider.defaultModel
        settingsStore.saveCloudModel(cloudModel)
        cloudAPIKey = CloudCredentialStore.loadAPIKey(account: provider.keychainAccount)
        resetAssistEngineForSourceChange()
    }

    func setCloudModel(_ model: String) {
        cloudModel = model
        settingsStore.saveCloudModel(model)
        resetAssistEngineForSourceChange()
    }

    func setCloudAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cloudAPIKey = trimmed
        CloudCredentialStore.saveAPIKey(trimmed, account: cloudProvider.keychainAccount)
        resetAssistEngineForSourceChange()
    }

    /// Сменился источник генерации (локально ↔ облако, модель, ключ) — выгружаем общий
    /// движок summary/экрана и сбрасываем актёр экрана, чтобы пересоздались на новом источнике.
    /// Живая сессия держит свой движок отдельно и подхватит источник при следующем старте.
    private func resetAssistEngineForSourceChange() {
        let old = assistLLM
        assistLLM = nil
        assistLLMIdentity = nil
        screenAssistActor = nil
        Task { await old?.unload() }
    }

    /// Фабрика движка генерации под текущие настройки: облако (opt-in, если включено и есть
    /// ключ) либо локальный MLX. За общим протоколом `LLMEngine` — оркестратор, summary и
    /// разбор экрана не различают источник. `warmUpSystemPrompt`/`onProgress` — только для MLX
    /// (A2-прогрев и прогресс скачивания); облако их игнорирует.
    private func makeLLMEngine(
        warmUpSystemPrompt: String? = nil,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) -> any LLMEngine {
        if cloudEnabled, !cloudAPIKey.isEmpty {
            switch cloudProvider {
            case .anthropic:
                return AnthropicLLMEngine(config: AnthropicLLMConfig(model: cloudModel, apiKey: cloudAPIKey))
            case .openAI:
                // OpenAI-совместимый `/chat/completions` — переиспользуем CloudLLMEngine.
                return CloudLLMEngine(config: CloudLLMConfig(
                    baseURL: URL(string: "https://api.openai.com/v1")!,
                    model: cloudModel,
                    apiKey: cloudAPIKey
                ))
            }
        }
        let llm = registry.info(id: selection.llmModelID, kind: .llm) ?? registry.llm[0]
        return MLXEngine(
            repo: llm.repo,
            displayName: llm.displayName,
            warmUpSystemPrompt: warmUpSystemPrompt,
            onProgress: onProgress
        )
    }

    /// Идентичность активного источника генерации — ключ кэша резидентного движка.
    private func assistEngineIdentity() -> String {
        if cloudEnabled, !cloudAPIKey.isEmpty { return "cloud:\(cloudProvider.rawValue):\(cloudModel)" }
        let llm = registry.info(id: selection.llmModelID, kind: .llm) ?? registry.llm[0]
        return "mlx:\(llm.repo)"
    }

    /// A8: общий резидентный движок генерации для summary и разбора экрана. Создаётся один
    /// раз под выбранную модель и удерживается в памяти; при смене модели — пересоздаётся.
    private func sharedAssistEngine() -> any LLMEngine {
        let identity = assistEngineIdentity()
        if let engine = assistLLM, assistLLMIdentity == identity { return engine }
        if let old = assistLLM { Task { await old.unload() } }
        let progress: @Sendable (DownloadProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.setDownload(p, label: "Модель генерации") }
        }
        let engine = makeLLMEngine(onProgress: progress)   // облако или MLX по настройкам
        assistLLM = engine
        assistLLMIdentity = identity
        return engine
    }

    // MARK: - Профили (именованные контексты)

    /// Добавить новый профиль и сделать его активным.
    @discardableResult
    func addProfile(name: String) -> UUID {
        let created = library.add(name: name.isEmpty ? "Новый профиль" : name)
        library.select(id: created.id)
        profileStore.saveLibrary(library)
        return created.id
    }

    func removeProfile(id: UUID) {
        library.remove(id: id)
        profileStore.saveLibrary(library)
    }

    func selectProfile(id: UUID) {
        library.select(id: id)
        profileStore.saveLibrary(library)
        // Пересоздавать актор разбора экрана не нужно: профиль приходит на каждый solve()
        // из актуального активного контекста. Живая сессия читает профиль при следующем старте.
    }

    func renameProfile(id: UUID, to name: String) {
        library.rename(id: id, to: name)
        profileStore.saveLibrary(library)
    }

    /// Заменить содержимое (секции) профиля по id.
    func updateProfileContent(id: UUID, profile: UserProfile) {
        library.update(id: id, profile: profile)
        profileStore.saveLibrary(library)
        screenAssistActor = nil
    }

    func updateMode(_ mode: ModeKind) {
        selectedMode = mode
        settingsStore.saveMode(mode)
    }

    // MARK: - Summary разговора

    /// Сгенерировать summary накопленного транскрипта (загружает LLM выбора).
    func summarize() {
        guard !summaryRunning, !conversation.finals.isEmpty else { return }
        summaryRunning = true
        summaryText = ""
        let transcript = conversation.finals
        let mode = selectedMode
        let engine = sharedAssistEngine()   // A8: общий резидентный движок (без пере-загрузки)
        summaryTask = Task { [weak self] in
            guard let self else { return }
            await engine.warmUp()
            let prompt = SummaryBuilder().build(transcript: transcript, mode: mode)
            do {
                for try await token in engine.generate(prompt: prompt, options: .summary) {
                    if Task.isCancelled { break }
                    self.summaryText += token
                }
            } catch {
                if !Task.isCancelled {
                    self.summaryText = "Не удалось сгенерировать summary — \(error.localizedDescription)"
                }
            }
            // НЕ выгружаем: движок остаётся резидентным для следующего summary/разбора экрана.
            self.summaryRunning = false
        }
    }

    func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryRunning = false
    }

    // MARK: - Управление сессией

    /// Живая сессия: системный звук собеседника + микрофон кандидата (оба реальные),
    /// WhisperKit/Parakeet (ASR) + MLX/облако (LLM) по выбору моделей. Микрофон опционален:
    /// отказ в разрешении не рубит сессию (подсказки по собеседнику идут и без него).
    /// Первый запуск скачивает модели.
    func startLive() {
        guard !isRunning else { return }
        conversation.reset()
        isRunning = true
        isLiveSession = true
        sessionStartedAt = Date()
        showOverlay()   // панель подсказок появляется по старту сессии (не висит с запуска)
        consumeTask = Task { [weak self] in
            guard let self else { return }
            // Микрофон опционален: спрашиваем разрешение, но отказ НЕ рубит сессию —
            // собеседник (системный звук) слушается отдельным TCC. При отказе канал
            // микрофона деградирует до фейка (без второй модели), флаг — для подсказки в UI.
            let micGranted = await MicrophonePermission.ensure()
            self.micPermissionDenied = !micGranted
            // Стоп мог быть нажат, пока висел диалог разрешений: не оживляем «мёртвую»
            // сессию, иначе движки (~4 ГБ) загрузятся в фоне и не будут остановлены.
            if Task.isCancelled { return }
            let session = self.makeLiveSession(micGranted: micGranted)
            self.session = session
            let stream = await session.start()
            for await event in stream {
                if Task.isCancelled { break }
                self.handleSessionEvent(event)
            }
        }
    }

    private func runSession(_ session: SessionActor) {
        self.session = session
        consumeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.start()
            for await event in stream {
                if Task.isCancelled { break }
                self.handleSessionEvent(event)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // Сохраняем живую сессию в историю (с шифрованием) — если был разговор.
        if isLiveSession {
            sessionStore.save(
                mode: selectedMode,
                startedAt: sessionStartedAt,
                finals: conversation.finals,
                suggestions: conversation.suggestions,
                summary: summaryText
            )
            runPostSessionEvaluation()
        }
        consumeTask?.cancel()
        consumeTask = nil
        let session = self.session
        self.session = nil
        Task { await session?.stop() }
        // Оверлей живёт в пределах сессии: чистим отображаемый разговор и прячем панель по стопу
        // (авто-закрытие в конце встречи). История уже сохранена в sessionStore выше;
        // reset() читается ПОСЛЕ save/eval, которые берут finals синхронно.
        conversation.reset()   // выставляет sessionState = .idle
        downloadProgress = nil
        hideOverlay()
    }

    /// Движок расшифровки по выбранной модели: id с префиксом "parakeet" → Parakeet
    /// (FluidAudio, single-pass по VAD-сегменту), иначе WhisperKit. Язык фиксируем по режиму.
    private func makeASREngine(
        _ asr: ModelInfo,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) -> any TranscriptionEngine {
        let lang = selectedMode == .englishCoach ? "en" : "ru"
        if asr.id.hasPrefix("parakeet") {
            return ParakeetEngine(source: .system, configuration: .init(languageCode: lang), onProgress: onProgress)
        }
        return WhisperKitEngine(source: .system, configuration: .init(model: asr.repo, language: lang), onProgress: onProgress)
    }

    /// Движок расшифровки для канала МИКРОФОНА (свой голос). Зеркалит `makeASREngine`,
    /// но помечает события `source: .microphone`. Модель выбирает `micTranscriptionModel`.
    private func makeASREngineMicrophone(
        _ asr: ModelInfo,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) -> any TranscriptionEngine {
        let lang = selectedMode == .englishCoach ? "en" : "ru"
        if asr.id.hasPrefix("parakeet") {
            return ParakeetEngine(source: .microphone, configuration: .init(languageCode: lang), onProgress: onProgress)
        }
        return WhisperKitEngine(source: .microphone, configuration: .init(model: asr.repo, language: lang), onProgress: onProgress)
    }

    /// Какую ASR-модель взять для микрофона (второй, опциональный канал). Микрофон даёт
    /// полный транскрипт диалога — точность тут менее критична, чем у собеседника, зато
    /// важно не держать вторую тяжёлую модель рядом с LLM. Логика: выбранная ASR уже лёгкая
    /// (whisper-base) → переиспользуем; памяти под вторую копию рядом с LLM хватает →
    /// берём ту же модель (лучшее качество); иначе откат на whisper-base (~0.15 ГБ).
    private func micTranscriptionModel(systemASR: ModelInfo, llm: ModelInfo) -> ModelInfo {
        if systemASR.id == "whisper-base" { return systemASR }
        let roomForSecond = Double(llm.minRAMGB) + systemASR.approxSizeGB + 1.0
        if device.totalRAMGB >= roomForSecond { return systemASR }
        return registry.info(id: "whisper-base", kind: .asr) ?? systemASR
    }

    /// Собирает живую сессию. Системный канал (собеседник) всегда реальный. Канал микрофона
    /// зависит от `micGranted`: при разрешении — реальный `MicrophoneCapture` + второй ASR
    /// (модель из `micTranscriptionModel`), иначе — фейк без модели (сессия живёт на собеседнике).
    private func makeLiveSession(micGranted: Bool) -> SessionActor {
        let profile = library.activeProfile   // активный именованный контекст
        let asr = registry.info(id: selection.asrModelID, kind: .asr) ?? registry.asr[0]
        let llm = registry.info(id: selection.llmModelID, kind: .llm) ?? registry.llm[0]
        let configuration = SessionConfiguration(
            mode: selectedMode,
            systemPrompt: SystemPrompts.text(for: selectedMode),
            // Весь профиль (опыт/проекты/стек/STAR), а не только обрезанное «о себе» —
            // раньше до постоянного контекста доезжал лишь about.prefix(240).
            profileSummary: profile.isEmpty ? nil : profile.promptSummary()
        )
        let asrProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.setDownload(progress, label: "Модель речи · \(asr.displayName)") }
        }
        let llmProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.setDownload(progress, label: "Модель генерации · \(llm.displayName)") }
        }
        let embedProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.setDownload(progress, label: "Модель контекста · e5-small") }
        }
        let tapError: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.handleSystemAudioError(message) }
        }
        // Микрофон кандидата — реальный, но ОПЦИОНАЛЬНЫЙ второй канал: даёт полный
        // транскрипт диалога (твои ответы), а не только вопросы собеседника. Чтобы не
        // держать вторую тяжёлую модель рядом с LLM, модель выбирается с оглядкой на RAM
        // (micTranscriptionModel). Без разрешения — фейк (без модели): сессия живёт на
        // системном звуке (собеседнике). Вопросы по своему каналу не детектим.
        let micASR = micTranscriptionModel(systemASR: asr, llm: llm)
        let micProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.setDownload(progress, label: "Микрофон · речь · \(micASR.displayName)") }
        }
        let micCapture: any AudioCapturing = micGranted
            ? MicrophoneCapture()
            : FakeAudioCapture(source: .microphone)
        let micTranscription: any TranscriptionEngine = micGranted
            ? makeASREngineMicrophone(micASR, onProgress: micProgress)
            : FakeTranscriptionEngine(source: .microphone, script: [])
        let dependencies = SessionActor.Dependencies(
            micCapture: micCapture,
            systemCapture: SystemAudioCapture(onSetupError: tapError),
            micTranscription: micTranscription,
            // Движок по выбору модели (Parakeet/WhisperKit). Язык фиксируем по режиму —
            // авто-детект Whisper прыгал на английский и галлюцинировал.
            systemTranscription: makeASREngine(asr, onProgress: asrProgress),
            detector: HeuristicQuestionDetector(),
            // RAG: профиль кандидата + база типовых Q&A по темам режима (доп. источник).
            context: ContextEngine(
                profile: profile,
                corpus: QACorpus.forMode(selectedMode),
                embedder: MLXEmbedder(onProgress: embedProgress)
            ),
            // Источник генерации по настройкам: облако (режим точности) или локальный MLX.
            // A2 (для MLX): греем реальным системным промптом режима — первый вопрос не платит
            // холодный префилл/JIT под форму промпта. Облако прогрева не требует.
            llm: makeLLMEngine(
                warmUpSystemPrompt: SystemPrompts.text(for: selectedMode),
                onProgress: llmProgress
            ),
            // Глоссарий терминов под режим (iOS/System Design) — чинит искажённые ASR-термины
            // детерминированно и даёт модели канонический словарь.
            promptBuilder: PromptBuilder(glossary: .forMode(selectedMode)),
            debugCapture: makeDebugCapture()
        )
        return SessionActor(configuration: configuration, dependencies: dependencies)
    }

    private func handleSessionEvent(_ event: SessionEvent) {
        conversation.apply(event)
        // Прогрев завершён (модели загружены) — убираем прогресс скачивания.
        if case .stateChanged(let state) = event, state != .warmingUp {
            downloadProgress = nil
        }
        // Фатальный сбой — сбрасываем флаг и выгружаем сессию (иначе индикатор «залипает»).
        if case .stateChanged(.failed) = event {
            isRunning = false
            teardownSession()
        }
    }

    /// Внятная ошибка захвата системного звука (приходит вне потока событий сессии).
    private func handleSystemAudioError(_ message: String) {
        guard isRunning else { return }
        conversation.lastError = message
        conversation.sessionState = .failed
        isRunning = false
        downloadProgress = nil
        teardownSession()
    }

    private func teardownSession() {
        let active = session
        session = nil
        Task { await active?.stop() }
    }

    private func setDownload(_ progress: DownloadProgress, label: String) {
        downloadProgress = progress
        downloadLabel = label
    }

    // MARK: - Плавающее окно

    func showOverlay() {
        if floatingController == nil {
            floatingController = FloatingPanelController(environment: self)
        }
        floatingController?.show()
    }

    /// Скрыть оверлей с экрана без уничтожения (orderOut) — повторный показ мгновенный, позиция
    /// сохраняется. Зовётся по стопу сессии, кнопкой × в баре и пунктом меню. Вернуть — ⌥⌘\.
    func hideOverlay() {
        floatingController?.hide()
    }

    /// Глобальный показать/скрыть оверлея (⌥⌘\). Постоянная панель — без пункта меню, поэтому
    /// единственный способ убрать её с экрана mid-call (поверх звонка фокус у оверлея нет, и
    /// внутри-оконный ⌘⇧H там не сработает). orderOut/orderFront, без уничтожения панели.
    func toggleOverlayVisibility() {
        if floatingController == nil {
            floatingController = FloatingPanelController(environment: self)
        }
        floatingController?.toggleVisibility()
    }

    // MARK: - Разбор экрана (OCR + LLM)

    private func registerGlobalHotkeys() {
        // ⌥⌘S — разбор экрана; ⌥⌘\ — показать/скрыть оверлей. Глобально (фокус в браузере/IDE).
        screenHotkey = GlobalHotkey(keyCode: GlobalHotkey.keyS, modifiers: GlobalHotkey.optionCommandMask) { [weak self] in
            self?.analyzeScreen()
        }
        overlayHotkey = GlobalHotkey(keyCode: GlobalHotkey.keyBackslash, modifiers: GlobalHotkey.optionCommandMask) { [weak self] in
            self?.toggleOverlayVisibility()
        }
    }

    /// Разобрать экран: сначала стелс-выбор области (как Cmd+Shift+4), затем захват выделения +
    /// OCR + генерация. Выбор области каждый раз — пользователь сам указывает прямоугольник с
    /// кодом, поэтому нет ни «захватили не то окно», ни OCR-шума (меню/док/сайдбар).
    func analyzeScreen() {
        // Повторный вызов (двойное ⌥⌘S) — no-op целиком: guard ВЫШЕ запроса доступа, чтобы и
        // системный prompt не дёргался повторно во время уже идущего разбора (в обеих ветках).
        guard !screenAssist.isRunning && !screenAnalyzing else { return }
        // Триггерим системный запрос доступа (если ещё не выдан), но НЕ блокируемся на его
        // ответе: у dev-сборок preflight врёт. Реальную проверку сделает сам захват —
        // если доступа нет, актёр/источник вернёт внятную ошибку.
        ScreenCapturePermission.request()

        // Стелс-оверлей выбора области: рамку/затемнение рисует наше окно (sharingType=.none),
        // собеседнику при шаринге не видно. Esc / случайный клик / повторный вызов → nil (отмена).
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let selection = await self.regionSelector.selectRegion() else { return }
            self.runScreenAnalysis(region: selection.region)
        }
    }

    /// Захват выбранной области + OCR + генерация. Развилка по наличию активной сессии:
    /// - В сессии (isRunning) — захват экрана идёт в ГОЛОСОВОЙ тракт: один ответ
    ///   «код + последний устный вопрос» в той же карте (insightCard), что и обычные подсказки.
    /// - Без сессии — прежний автономный разбор (ScreenAssistActor → screenAssistArea, Уровень 1).
    private func runScreenAnalysis(region: CaptureRegion) {
        showOverlay()

        // Активная сессия — путь через голосовой тракт: захватываем текст экрана и отдаём его
        // в SessionActor.solveScreen, ответ придёт в общий поток событий → insightCard.
        if isRunning, let session {
            screenAnalyzing = true
            let actor = ensureScreenAssistActor()
            // Последний устный вопрос интервьюера (если есть) — solveScreen сам подставит
            // дефолтную инструкцию при пустом.
            let spokenQuestion = conversation.lastQuestion ?? ""
            screenAssistTask?.cancel()
            screenAssistTask = Task { [weak self] in
                guard let self else { return }
                // По завершении/ошибке снимаем индикатор захвата на главном актёре (тип @MainActor,
                // повторяем существующий паттерн хопа на MainActor из Task).
                defer { Task { @MainActor in self.screenAnalyzing = false } }
                let screenText: String
                do {
                    screenText = try await actor.captureText(region: region)
                } catch {
                    if !Task.isCancelled {
                        self.conversation.lastError = "Не удалось прочитать экран — \(error.localizedDescription)"
                    }
                    return
                }
                if Task.isCancelled { return }
                let trimmed = screenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.conversation.lastError = "На экране не найдено текста для разбора"
                    return
                }
                // Один ответ «код + устный вопрос» в той же карте подсказки. Вопрос зафиксирован
                // ДО Task (spokenQuestion), как и в ветке без сессии — одна точка чтения lastQuestion.
                // Обращение к актёру требует await; сам solveScreen не блокируется на генерации
                // (запускает Task внутри).
                await session.solveScreen(question: spokenQuestion, screenText: trimmed)
            }
            return
        }

        // Нет сессии — прежний автономный разбор (Уровень 1): ScreenAssistActor → screenAssistArea.
        let actor = ensureScreenAssistActor()
        // Устный вопрос интервьюера — главный сигнал типа задания. Берём последний
        // распознанный вопрос; если его ещё нет — короткий хвост последних реплик собеседника
        // (system), чтобы разбор экрана учитывал, что спросили вслух.
        let spokenQuestion = currentSpokenQuestion()
        // Актуальный профиль на момент хоткея (пользователь мог переключить контекст).
        let profile = library.activeProfile
        let profileSummary = profile.isEmpty ? "" : profile.promptSummary()
        screenAssistTask?.cancel()
        screenAssistTask = Task { [weak self] in
            guard let self else { return }
            let stream = await actor.solve(question: spokenQuestion, profileSummary: profileSummary, region: region)
            for await event in stream {
                if Task.isCancelled { break }
                self.screenAssist.apply(event)
                // Модель прогрелась (пошла генерация) или упали — прячем прогресс скачивания.
                if case .stateChanged(let phase) = event, phase != .capturing {
                    self.downloadProgress = nil
                }
            }
        }
    }

    private func ensureScreenAssistActor() -> ScreenAssistActor {
        if let actor = screenAssistActor { return actor }
        let source = VisionScreenTextSource(
            excludeBundleIDs: [Bundle.main.bundleIdentifier ?? "com.konstantin.sotto"]
        )
        let actor = ScreenAssistActor(
            source: source,
            llm: sharedAssistEngine(),   // A8: общий резидентный движок (как у summary)
            promptBuilder: CodeAssistPromptBuilder()
            // Профиль и вопрос интервьюера меняются к каждому разбору — передаём их в solve(),
            // а не вшиваем в актор.
        )
        screenAssistActor = actor
        return actor
    }

    /// Устный вопрос интервьюера для разбора экрана. Приоритет — детектированный
    /// `lastQuestion`; запасной вариант — склейка 1–3 последних реплик собеседника (system),
    /// если явного вопроса ещё нет. Хвост держим коротким, чтобы не раздувать промпт.
    private func currentSpokenQuestion() -> String {
        if let question = conversation.lastQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            return question
        }
        let tail = conversation.finals
            .filter { $0.source == .system }
            .suffix(3)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return tail.joined(separator: " ")
    }

    // MARK: - Тест микрофона (реальный аудио-конвейер)

    func toggleMicTest() {
        micTestRunning ? stopMicTest() : startMicTest()
    }

    private func startMicTest() {
        micPermissionDenied = false
        micRMS = 0
        micChunkCount = 0
        micSpeechRatio = 0
        micDroppedBlocks = 0

        micTask = Task { [weak self] in
            guard let self else { return }
            guard await MicrophonePermission.ensure() else {
                self.micPermissionDenied = true
                return
            }
            let capture = MicrophoneCapture()
            let vad = EnergyVAD()
            self.micTestRunning = true

            var total = 0
            var speech = 0
            for await chunk in capture.stream() {
                if Task.isCancelled { break }
                let result = vad.process(chunk.samples)
                total += 1
                if result.isSpeech { speech += 1 }
                self.micRMS = result.rms
                self.micChunkCount = total
                self.micSpeechRatio = Double(speech) / Double(total)
                self.micDroppedBlocks = capture.droppedBlocks
            }
        }
    }

    private func stopMicTest() {
        micTestRunning = false
        micTask?.cancel()
        micTask = nil
    }
}
