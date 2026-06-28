import Foundation
import CoreML
import SottoCore
@preconcurrency import WhisperKit

/// Реализация `TranscriptionEngine` на WhisperKit (Core ML + Apple Neural Engine).
///
/// Потоковая расшифровка по скользящему окну: пока идёт речь — каждые ~0.4 с
/// пере-расшифровываем накопленное окно и отдаём `.partial`; на устойчивой паузе
/// (VAD) фиксируем `.final` и начинаем новое окно. На один движок — одна активная
/// сессия (состояние потока хранится в свойствах актёра).
///
/// Замечание по производительности: пере-расшифровка растущего окна — упрощение для
/// фазы 3; оптимизация (инкрементальное декодирование, кэш) — в фазе 8.
public actor WhisperKitEngine: TranscriptionEngine {

    public struct Configuration: Sendable {
        public var model: String
        public var language: String?          // nil → автоопределение (RU/EN)
        public var partialInterval: TimeInterval
        public var silenceHangoverFrames: Int // кадров тишины (0.1 с) до фиксации
        public var maxWindowSeconds: Double

        public init(
            model: String = "openai_whisper-large-v3-v20240930_turbo",
            language: String? = nil,
            partialInterval: TimeInterval = 4.0,    // каждый партиал = полный проход энкодера (паддинг до 30 c). Реже партиалы → выше пропускная способность, движок успевает за реалтаймом и drop-to-live меньше роняет
            silenceHangoverFrames: Int = 8,         // A7 откачен: 0.6 c дробил вопросы; 0.8 c надёжнее склеивает фразу
            maxWindowSeconds: Double = 8             // окно ограничено → финал наступает регулярно, даже без паузы
        ) {
            self.model = model
            self.language = language
            self.partialInterval = partialInterval
            self.silenceHangoverFrames = silenceHangoverFrames
            self.maxWindowSeconds = maxWindowSeconds
        }
    }

    private let source: SottoCore.AudioSource
    private let config: Configuration
    private let onProgress: (@Sendable (DownloadProgress) -> Void)?
    private var whisperKit: WhisperKit?
    public private(set) var loadedModel: String?

    // Состояние одной потоковой сессии.
    private var window: [Float] = []
    private var hadSpeech = false
    private var silenceRun = 0
    private var samplesSincePartial = 0
    private var lastText = ""
    private var startTimestamp: TimeInterval = 0
    /// Текст последнего выданного финала — для дедупа (повтор-галлюцинации). Живёт вне
    /// `resetStreamState()`: сравниваем между окнами в пределах одной сессии.
    private var lastEmittedFinalText = ""

    public init(
        source: SottoCore.AudioSource,
        configuration: Configuration = Configuration(),
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) {
        self.source = source
        self.config = configuration
        self.onProgress = onProgress
    }

    // MARK: - TranscriptionEngine

    public func warmUp() async throws {
        try await ensureLoaded()
    }

    /// Эталонная расшифровка целого аудио одним проходом (полный контекст, без потоковых
    /// окон) — точнее живой потоковой; нужна для авто-оценки качества после сессии.
    public func transcribeWhole(_ samples: [Float]) async throws -> String {
        try await ensureLoaded()
        return try await runInference(samples).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func unload() async {
        whisperKit = nil
        AppLog.transcription.info("WhisperKit: модель выгружена")
    }

    public nonisolated func transcribe(_ audio: AsyncStream<SottoCore.AudioChunk>) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(audio, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Загрузка модели

    private func ensureLoaded() async throws {
        guard whisperKit == nil else { return }
        do {
            try await load()
        } catch {
            // Прагматичная авто-перекачка: стереть (возможно битую) папку и скачать заново один раз.
            AppLog.transcription.error("WhisperKit: загрузка не удалась, перекачиваю модель — \(error.localizedDescription, privacy: .public)")
            ModelManager.deleteWhisperVariant(config.model)
            try await load()
        }
    }

    private func load() async throws {
        let onProgress = self.onProgress
        // Если модель уже на диске — грузим из папки напрямую, БЕЗ обращения к сети
        // (иначе WhisperKit идёт на HuggingFace проверять файлы, и это может зависнуть).
        // Иначе — качаем в наш каталог с прогрессом.
        let existing = ModelManager.whisperVariantFolder(variant: config.model)
        let folder: URL
        if FileManager.default.fileExists(atPath: existing.path) {
            folder = existing
        } else {
            folder = try await WhisperKit.download(
                variant: config.model,
                downloadBase: ModelManager.modelsDirectory,
                progressCallback: { progress in onProgress?(DownloadProgress(progress)) }
            )
        }
        // CPU+GPU (Metal), без ANE: нет долгой ANE-компиляции при старте. С лёгкой моделью
        // (small) GPU успевает в реальном времени, поэтому финалы наступают и идут подсказки.
        whisperKit = try await WhisperKit(
            modelFolder: folder.path(percentEncoded: false),
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        loadedModel = config.model
        AppLog.transcription.info("WhisperKit загружен: \(self.config.model, privacy: .public)")
    }

    // MARK: - Потоковая расшифровка

    private func run(_ audio: AsyncStream<SottoCore.AudioChunk>, _ continuation: AsyncStream<TranscriptEvent>.Continuation) async {
        do {
            try await ensureLoaded()
        } catch {
            AppLog.transcription.error("расшифровка не запущена: модель не загружена")
            continuation.finish()
            return
        }
        guard whisperKit != nil else { continuation.finish(); return }

        resetStreamState()
        lastEmittedFinalText = ""   // дедуп финалов — в пределах одной сессии
        let partialSamples = Int(16_000 * config.partialInterval)
        let maxSamples = Int(16_000 * config.maxWindowSeconds)
        let vad = SottoCore.EnergyVAD()
        // Отслеживание разрывов из-за drop-to-live (живут вне stream-state: сравниваем с
        // последним РЕАЛЬНО пришедшим чанком, даже после сброса окна).
        var lastChunkStart: TimeInterval?
        var lastChunkDuration: TimeInterval = 0

        for await chunk in audio {
            if Task.isCancelled { break }
            let chunkDuration = Double(chunk.samples.count) / Double(chunk.sampleRate)

            // Разрыв: drop-to-live выбросил кусок аудио (старт текущего чанка прыгнул
            // вперёд). Фиксируем накопленное окно и начинаем новое с текущего чанка —
            // иначе склеим несмежную речь и расшифровка поедет.
            if !window.isEmpty, let prevStart = lastChunkStart,
               SottoCore.AudioBackpressure.isDiscontinuity(
                   previousStart: prevStart,
                   previousDuration: lastChunkDuration,
                   nextStart: chunk.timestamp
               ) {
                if hadSpeech {
                    await emitFinal(into: continuation, end: prevStart + lastChunkDuration)
                } else {
                    resetStreamState()
                }
            }
            lastChunkStart = chunk.timestamp
            lastChunkDuration = chunkDuration

            if window.isEmpty { startTimestamp = chunk.timestamp }
            window.append(contentsOf: chunk.samples)
            samplesSincePartial += chunk.samples.count

            let vadResult = vad.process(chunk.samples)
            if vadResult.isSpeech {
                hadSpeech = true
                silenceRun = 0
            } else {
                silenceRun += 1
            }

            if hadSpeech, samplesSincePartial >= partialSamples {
                samplesSincePartial = 0
                if let text = try? await runInference(window), !text.isEmpty {
                    lastText = text
                    continuation.yield(.partial(TranscriptSegment(
                        source: source, text: text, isFinal: false,
                        start: startTimestamp, end: chunk.timestamp
                    )))
                }
            }

            if hadSpeech, silenceRun >= config.silenceHangoverFrames {
                await emitFinal(into: continuation, end: chunk.timestamp)        // речь кончилась на паузе
            } else if window.count >= maxSamples {
                if hadSpeech {
                    await emitFinal(into: continuation, end: chunk.timestamp)    // длинная речь без пауз — режем окно
                } else {
                    // Окно без единого кадра речи = тишина/шум. НЕ запускаем инференс:
                    // Whisper на тишине галлюцинирует «титры»/«спасибо за просмотр».
                    resetStreamState()
                }
            }
        }

        if hadSpeech, !window.isEmpty {
            await emitFinal(into: continuation, end: startTimestamp + Double(window.count) / 16_000)
        }
        continuation.finish()
    }

    private func emitFinal(into continuation: AsyncStream<TranscriptEvent>.Continuation, end: TimeInterval) async {
        // Если с последнего партиала почти не было нового аудио (например, финал по
        // maxWindow сразу после партиала на том же окне) — партиал уже всё расшифровал,
        // не гоняем самый дорогой проход заново. Иначе — досчитываем хвост.
        let reuseThreshold = Int(16_000 * 0.4)
        let raw: String
        if samplesSincePartial < reuseThreshold, !lastText.isEmpty {
            raw = lastText
        } else {
            raw = (try? await runInference(window)) ?? lastText
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Пропускаем пустое и дословный повтор прошлого финала — почти всегда это
        // повтор-галлюцинация Whisper (одни и те же «титры» на тишине/шуме).
        if !text.isEmpty, text != lastEmittedFinalText {
            lastEmittedFinalText = text
            continuation.yield(.final(TranscriptSegment(
                source: source, text: text, isFinal: true,
                start: startTimestamp, end: end
            )))
        }
        resetStreamState()
    }

    private func runInference(_ samples: [Float]) async throws -> String {
        guard let whisperKit else { return "" }
        let options = DecodingOptions(
            task: .transcribe,
            language: config.language,
            detectLanguage: config.language == nil ? true : nil
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let cleaned = Self.cleanup(results.map { $0.text }.joined(separator: " "))
        // Срезаем известные галлюцинации на тишине/шуме (титры, «спасибо за просмотр»).
        return SottoCore.TranscriptSanitizer.stripHallucinations(cleaned)
    }

    /// Убрать спец-маркеры WhisperKit (тишина/звуки): `[BLANK_AUDIO]`, `[ Silence ]`,
    /// `[Music]` и т.п. — они мусорят расшифровку и детект вопроса.
    private static func cleanup(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetStreamState() {
        window.removeAll(keepingCapacity: true)
        hadSpeech = false
        silenceRun = 0
        samplesSincePartial = 0
        lastText = ""
        startTimestamp = 0
    }
}
