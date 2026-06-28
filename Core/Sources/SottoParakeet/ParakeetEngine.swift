import Foundation
import SottoCore
@preconcurrency import FluidAudio

/// Реализация `TranscriptionEngine` на NVIDIA Parakeet-TDT v3 (25 языков вкл. русский)
/// через FluidAudio (CoreML, ANE/GPU).
///
/// Отличие от `WhisperKitEngine`: нет 30-сек паддинга энкодера, RNN-T/TDT декод дёшев →
/// движок легко успевает за реальным временем (drop-to-live почти не роняет аудио).
/// Для A6 (спекулятивный старт ответа до конца вопроса) каждые `partialInterval` секунд
/// речи перезапускаем инференс на растущем окне и шлём `.partial`; на VAD-паузе (или по cap
/// окна) фиксируем `.final`. Партиал дёшев (TDT single-pass), поэтому лишние проходы почти
/// бесплатны — именно это включает A6 на дефолтном движке и прячет «налог на тишину».
public actor ParakeetEngine: TranscriptionEngine {

    public struct Configuration: Sendable {
        public var silenceHangoverFrames: Int   // кадров тишины (0.1 с) до фиксации сегмента
        public var maxWindowSeconds: Double      // потолок длины сегмента (Parakeet без 30-сек паддинга — можно длиннее)
        public var languageCode: String?         // "ru"/"en"/… фиксируем по режиму; nil → авто-детект
        public var partialInterval: Double        // как часто слать `.partial` (сек речи) для A6

        // A7 ОТКАЧЕН: укороченный hangover (0.5 c) дробил длинные вопросы на части и LLM
        // отвечал на обрывок. 0.8 c тишины надёжнее склеивает многопредложенный вопрос в
        // один финал. (Снижать время-до-финала будем иначе — без риска фрагментации.)
        //
        // partialInterval 0.4 c: достаточно часто, чтобы A6 поймал формирующийся вопрос
        // задолго до `.final`, и достаточно редко, чтобы лишние проходы инференса не грузили ANE.
        public init(silenceHangoverFrames: Int = 8, maxWindowSeconds: Double = 24, languageCode: String? = nil, partialInterval: Double = 0.4) {
            self.silenceHangoverFrames = silenceHangoverFrames
            self.maxWindowSeconds = maxWindowSeconds
            self.languageCode = languageCode
            self.partialInterval = partialInterval
        }
    }

    private let source: SottoCore.AudioSource
    private let config: Configuration
    private let onProgress: (@Sendable (SottoCore.DownloadProgress) -> Void)?
    private var asr: AsrManager?
    private var decoderLayers = 2
    private var language: Language?
    public private(set) var isLoaded = false

    // Состояние одной потоковой сессии.
    private var window: [Float] = []
    private var hadSpeech = false
    private var silenceRun = 0
    private var startTimestamp: TimeInterval = 0
    private var lastEmittedFinalText = ""
    private var samplesSincePartial = 0   // сэмплов с последнего `.partial` (троттлинг A6)
    private var lastText = ""             // последний распознанный текст окна (партиал → переиспользуем в финале)

    public init(
        source: SottoCore.AudioSource,
        configuration: Configuration = Configuration(),
        onProgress: (@Sendable (SottoCore.DownloadProgress) -> Void)? = nil
    ) {
        self.source = source
        self.config = configuration
        self.onProgress = onProgress
    }

    // MARK: - TranscriptionEngine

    public func warmUp() async throws {
        try await ensureLoaded()
    }

    public func unload() async {
        asr = nil
        isLoaded = false
        AppLog.transcription.info("Parakeet: модель выгружена")
    }

    /// Эталонная расшифровка целого аудио одним проходом — для авто-оценки качества.
    public func transcribeWhole(_ samples: [Float]) async throws -> String {
        try await ensureLoaded()
        return try await runInference(samples)
    }

    public nonisolated func transcribe(_ audio: AsyncStream<SottoCore.AudioChunk>) -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(audio, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Загрузка модели

    private func ensureLoaded() async throws {
        guard asr == nil else { return }
        onProgress?(SottoCore.DownloadProgress(fraction: 0))
        // FluidAudio сам качает и кэширует CoreML-модели Parakeet v3 (по умолчанию v3 = 25 языков вкл. ru).
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager()
        try await manager.loadModels(models)
        decoderLayers = await manager.decoderLayerCount
        language = config.languageCode.flatMap(Language.init(rawValue:))
        asr = manager
        isLoaded = true
        onProgress?(SottoCore.DownloadProgress(fraction: 1))
        AppLog.transcription.info("Parakeet загружен: parakeet-tdt-0.6b-v3")
    }

    // MARK: - Потоковая расшифровка (VAD-сегмент → один проход)

    private func run(_ audio: AsyncStream<SottoCore.AudioChunk>, _ continuation: AsyncStream<TranscriptEvent>.Continuation) async {
        do {
            try await ensureLoaded()
        } catch {
            AppLog.transcription.error("Parakeet: модель не загружена — \(error.localizedDescription, privacy: .public)")
            continuation.finish()
            return
        }

        resetStreamState()
        lastEmittedFinalText = ""
        let maxSamples = Int(16_000 * config.maxWindowSeconds)
        let partialSamples = Int(16_000 * config.partialInterval)
        let vad = SottoCore.EnergyVAD()
        var lastChunkStart: TimeInterval?
        var lastChunkDuration: TimeInterval = 0

        for await chunk in audio {
            if Task.isCancelled { break }
            let chunkDuration = Double(chunk.samples.count) / Double(chunk.sampleRate)

            // Разрыв из-за drop-to-live: зафиксировать набранный сегмент и начать новый.
            if !window.isEmpty, let prevStart = lastChunkStart,
               SottoCore.AudioBackpressure.isDiscontinuity(
                   previousStart: prevStart, previousDuration: lastChunkDuration, nextStart: chunk.timestamp
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

            if vad.process(chunk.samples).isSpeech {
                hadSpeech = true
                silenceRun = 0
            } else {
                silenceRun += 1
            }

            // A6: пока вопрос ещё звучит, периодически отдаём промежуточную гипотезу —
            // оркестратор стартует спекулятивный ответ, не дожидаясь `.final` (налог на тишину).
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
                    await emitFinal(into: continuation, end: chunk.timestamp)    // длинный монолог без пауз — режем
                } else {
                    resetStreamState()                                          // тишина/шум — не транскрибируем
                }
            }
        }

        if hadSpeech, !window.isEmpty {
            await emitFinal(into: continuation, end: startTimestamp + Double(window.count) / 16_000)
        }
        continuation.finish()
    }

    private func emitFinal(into continuation: AsyncStream<TranscriptEvent>.Continuation, end: TimeInterval) async {
        // Если с последнего партиала почти не было нового аудио (финал сразу после партиала
        // на том же окне) — партиал уже всё распознал, не гоняем дорогой проход заново.
        let reuseThreshold = Int(16_000 * 0.4)
        let raw: String
        if samplesSincePartial < reuseThreshold, !lastText.isEmpty {
            raw = lastText
        } else {
            raw = (try? await runInference(window)) ?? lastText
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let asr else { return "" }
        // Слишком короткие куски (<~0.2 c) Parakeet смысла гнать нет.
        guard samples.count >= 3_200 else { return "" }
        // Свежее состояние декодера на каждый сегмент — сегменты независимы (single-pass).
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(samples, decoderState: &state, language: language)
        return SottoCore.TranscriptSanitizer.stripHallucinations(result.text)
    }

    private func resetStreamState() {
        window.removeAll(keepingCapacity: true)
        hadSpeech = false
        silenceRun = 0
        startTimestamp = 0
        samplesSincePartial = 0
        lastText = ""
    }
}
