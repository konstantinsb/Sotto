import Foundation
import SottoCore
@preconcurrency import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
@preconcurrency import MLXHuggingFace
@preconcurrency import HuggingFace
@preconcurrency import Tokenizers

/// Реализация `LLMEngine` на MLX (Metal, unified memory).
///
/// Модель (`ModelContainer`) загружается один раз при прогреве и удерживается в памяти.
/// На каждый запрос создаётся свежая `ChatSession` (системные инструкции = `prompt.system`),
/// история не накапливается — промпт остаётся ограниченным. Вывод — потоковый, по чанкам.
///
/// Оптимизации задержки:
/// - A2: прогрев греет РЕАЛЬНЫМ системным промптом (`warmUpSystemPrompt`), а не "hi" —
///   на первом реальном вопросе не платим JIT/префилл под фактическую форму промпта.
/// - A3: `GenerationOptions` → `GenerateParameters` (предел длины + greedy при t=0).
/// - A1 (ЭКСПЕРИМЕНТАЛЬНО, по умолчанию выключено): префикс-кэш системного промпта.
///   Строится один раз при прогреве, переиспользуется на каждом запросе (`instructions: nil`),
///   чтобы не префилить системный промпт заново. На сбой/несовпадение — безопасный откат к
///   обычной свежей сессии. ВКЛЮЧАТЬ только после проверки связности вывода в Xcode на
///   выбранной (плотной) модели — для гибридных/SSM моделей переиспользование кэша ненадёжно.
///
/// ВНИМАНИЕ: таргет компилируется только через Xcode (Metal-шейдеры).
public actor MLXEngine: LLMEngine {
    public nonisolated let modelName: String
    private let repo: String
    private let onProgress: (@Sendable (DownloadProgress) -> Void)?
    private let warmUpSystemPrompt: String?
    private let usePrefixCache: Bool
    private var container: ModelContainer?
    // Текущая задача загрузки модели — чтобы параллельные вызовы не загрузили её дважды.
    private var loadTask: Task<Void, Error>?
    // A1: файл с KV-кэшем системного префикса и system-промпт, под который он построен.
    private var prefixCacheURL: URL?
    private var prefixCacheSystem: String?

    public init(
        repo: String = "mlx-community/Qwen3-4B-4bit",
        displayName: String? = nil,
        warmUpSystemPrompt: String? = nil,
        usePrefixCache: Bool = false,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) {
        self.repo = repo
        self.modelName = displayName ?? repo
        self.warmUpSystemPrompt = warmUpSystemPrompt
        self.usePrefixCache = usePrefixCache
        self.onProgress = onProgress
    }

    public func warmUp() async {
        do {
            try await ensureLoaded()
            await primeKernels()
            if usePrefixCache, let system = warmUpSystemPrompt {
                await buildPrefixCache(system: system)
            }
        } catch {
            AppLog.llm.error("MLX: прогрев не удался — \(error.localizedDescription, privacy: .public)")
        }
    }

    public func unload() async {
        container = nil
        loadTask = nil
        // A1: удаляем temp-файл префикс-кэша, иначе он копится в /tmp при пере-прогревах.
        if let url = prefixCacheURL { try? FileManager.default.removeItem(at: url) }
        prefixCacheURL = nil
        prefixCacheSystem = nil
        Memory.clearCache()
        AppLog.llm.info("MLX: модель выгружена, GPU-кэш очищен")
    }

    /// Холостой короткий инференс — форсирует JIT-компиляцию Metal-ядер во время прогрева,
    /// а не на первом реальном вопросе пользователя. A2: если задан реальный системный
    /// промпт — греем именно им (форма промпта совпадёт с боевой → префилл первого вопроса
    /// дешевле), иначе нейтральное "hi".
    private func primeKernels() async {
        guard let container else { return }
        let session = warmUpSystemPrompt.map { ChatSession(container, instructions: $0) }
            ?? ChatSession(container)
        let probe = warmUpSystemPrompt == nil ? "hi" : "Готов?"
        do {
            var produced = 0
            for try await _ in session.streamResponse(to: probe) {
                produced += 1
                if produced >= 2 { break }
            }
        } catch {
            AppLog.llm.error("MLX: холостой прогрев пропущен — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A1: построить KV-кэш системного префикса один раз (при прогреве). Делаем короткое
    /// порождение с `instructions = system`, затем сохраняем кэш на диск. На каждом запросе
    /// он подгружается свежей копией (см. `run`), чтобы не префилить системный промпт заново.
    /// Любой сбой — просто отключает кэш для этого system (откат к обычному пути в `run`).
    private func buildPrefixCache(system: String) async {
        guard let container else { return }
        do {
            var params = GenerateParameters()
            params.maxTokens = 1
            let session = ChatSession(container, instructions: system, generateParameters: params)
            for try await _ in session.streamResponse(to: " ") { break }
            // Удаляем предыдущий файл кэша (пере-прогрев на другой system) — не копим в /tmp.
            if let old = prefixCacheURL { try? FileManager.default.removeItem(at: old) }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sotto-prefix-\(UUID().uuidString).safetensors")
            try await session.saveCache(to: url)
            prefixCacheURL = url
            prefixCacheSystem = system
            AppLog.llm.info("MLX: префикс-кэш системного промпта построен")
        } catch {
            AppLog.llm.error("MLX: префикс-кэш не построен, откат к обычному пути — \(error.localizedDescription, privacy: .public)")
            prefixCacheURL = nil
            prefixCacheSystem = nil
        }
    }

    public nonisolated func generate(prompt: Prompt, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(prompt, options, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GenerationOptions` → `GenerateParameters`: предел длины и температура (0 → greedy).
    private static func makeParameters(_ options: GenerationOptions) -> GenerateParameters {
        var params = GenerateParameters()
        params.maxTokens = options.maxTokens
        params.temperature = options.temperature
        return params
    }

    // MARK: - Внутреннее

    private func ensureLoaded() async throws {
        if container != nil { return }
        // Один общий движок теперь делят summary и разбор экрана (A8) — два первых вызова
        // могут пересечься. Actor реентерабелен, поэтому без флага оба прошли бы guard и
        // загрузили модель ДВАЖДЫ (~ГБ). Сводим параллельные загрузки к одной задаче.
        if let loadTask { try await loadTask.value; return }
        let task = Task { try await self.loadContainer() }
        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil   // дать повторить попытку после сбоя
            throw error
        }
        loadTask = nil
    }

    private func loadContainer() async throws {
        guard container == nil else { return }
        // Ограничиваем кэш буферов GPU — бережём память на 16 ГБ рядом с Whisper.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
        let configuration = ModelConfiguration(id: repo)
        let onProgress = self.onProgress
        // Загрузчик «сначала локально»: при наличии модели — без сети (наш каталог).
        container = try await loadModelContainer(
            from: HuggingFaceDownload.cachedFirstDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { progress in onProgress?(DownloadProgress(progress)) }
        )
        AppLog.llm.info("MLX модель загружена: \(self.repo, privacy: .public)")
    }

    private func run(_ prompt: Prompt, _ options: GenerationOptions, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            try await ensureLoaded()
        } catch {
            AppLog.llm.error("MLX: генерация не запущена — модель не загружена — \(error.localizedDescription, privacy: .public)")
            continuation.finish(throwing: error)
            return
        }
        guard let container else { continuation.finish(throwing: LLMEngineError.modelNotLoaded); return }

        let params = Self.makeParameters(options)
        // A1: при наличии префикс-кэша для ровно этого system — стартуем из него (свежая
        // копия с диска на каждый запрос), instructions: nil (системный промпт уже в кэше,
        // иначе повторная токенизация). Несовпадение/сбой загрузки — обычная свежая сессия.
        let session: ChatSession
        if usePrefixCache, prompt.system == prefixCacheSystem, let url = prefixCacheURL,
           let loaded = try? loadPromptCache(url: url) {
            session = ChatSession(container, instructions: nil, cache: loaded.0, generateParameters: params)
        } else {
            session = ChatSession(container, instructions: prompt.system, generateParameters: params)
        }
        // Qwen3: отключаем «рассуждения» (<think>…</think>) — для живых подсказок нужен
        // чистый ответ сразу и без лишней задержки. Для не-Qwen маркер просто игнорируется.
        let userMessage = prompt.user + "\n/no_think"
        // Даже с /no_think Qwen3 эмитит ПУСТОЙ блок <think></think> — вырезаем его из потока,
        // иначе он попадал в подсказку как мусор «<think>  </think>».
        var stripper = ThinkTagStripper()
        do {
            for try await chunk in session.streamResponse(to: userMessage) {
                if Task.isCancelled { break }
                let cleaned = stripper.feed(chunk)
                if !cleaned.isEmpty { continuation.yield(cleaned) }
            }
            let tail = stripper.finish()
            if !tail.isEmpty { continuation.yield(tail) }
            continuation.finish()
        } catch {
            // Отмена (стоп сессии) — штатно, не ошибка. Реальный сбой — пробрасываем.
            if Task.isCancelled {
                continuation.finish()
            } else {
                AppLog.llm.error("MLX: генерация прервана — \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
    }
}
