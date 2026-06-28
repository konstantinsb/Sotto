import Foundation

/// Тип модели в реестре.
public enum ModelKind: String, Sendable, Codable {
    case asr   // распознавание речи (WhisperKit)
    case llm   // генерация (MLX)
}

/// Описание одной модели в реестре (метаданные; без зависимостей от движков).
public struct ModelInfo: Sendable, Identifiable, Hashable {
    public let id: String          // стабильный идентификатор выбора (наш)
    public let kind: ModelKind
    public let displayName: String
    public let repo: String        // идентификатор для движка (имя WhisperKit / HF-репо MLX)
    public let approxSizeGB: Double
    public let minRAMGB: Int
    public let tier: DeviceCapabilities.QualityTier

    public init(
        id: String,
        kind: ModelKind,
        displayName: String,
        repo: String,
        approxSizeGB: Double,
        minRAMGB: Int,
        tier: DeviceCapabilities.QualityTier
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.repo = repo
        self.approxSizeGB = approxSizeGB
        self.minRAMGB = minRAMGB
        self.tier = tier
    }
}

/// Реестр доступных моделей. Метаданные, по которым строится пикер в Settings,
/// а движки получают `repo` для загрузки.
public struct ModelRegistry: Sendable {
    public let asr: [ModelInfo]
    public let llm: [ModelInfo]

    public init(asr: [ModelInfo], llm: [ModelInfo]) {
        self.asr = asr
        self.llm = llm
    }

    public func models(of kind: ModelKind) -> [ModelInfo] {
        kind == .asr ? asr : llm
    }

    public func info(id: String) -> ModelInfo? {
        (asr + llm).first { $0.id == id }
    }

    /// Поиск с учётом типа: ASR-слот не примет LLM-id и наоборот.
    public func info(id: String, kind: ModelKind) -> ModelInfo? {
        models(of: kind).first { $0.id == id }
    }

    /// Рекомендованный LLM по объёму памяти устройства — оптимизация под СКОРОСТЬ.
    /// На слабых машинах (`.fast`, < 16 ГБ) берём самую маленькую модель (выше токены/с,
    /// ниже задержка до первого токена, меньше со-резидентное давление на память рядом с
    /// ASR и эмбеддером). При достатке памяти — сбалансированный дефолт (`qwen3-4b`), если
    /// он влезает; иначе самая маленькая из подходящих. 8B не выбираем автоматически — она
    /// медленнее; пользователь может включить её вручную ради качества.
    /// Возвращает существующий id из реестра.
    public func recommendedLLMID(for device: DeviceCapabilities) -> String {
        let ramGB = Int(device.totalRAMGB.rounded(.down))
        let affordable = llm.filter { $0.minRAMGB <= ramGB }
        let pool = affordable.isEmpty ? llm : affordable
        let smallest = pool.min { $0.approxSizeGB < $1.approxSizeGB }?.id
        switch device.recommendedTier {
        case .fast:
            return smallest ?? llm.first?.id ?? ModelSelection.default.llmModelID
        case .balanced, .quality:
            let balanced = pool.first { $0.id == ModelSelection.default.llmModelID }?.id
            return balanced ?? smallest ?? llm.first?.id ?? ModelSelection.default.llmModelID
        }
    }

    public static let `default` = ModelRegistry(
        asr: [
            // Parakeet TDT v3 (NVIDIA, 25 языков вкл. русский) через FluidAudio (CoreML/ANE).
            // RNN-T без 30-сек паддинга → расшифровка по сегменту один раз, ~много× реалтайма.
            // id с префиксом "parakeet" → AppEnvironment поднимает ParakeetEngine, иначе WhisperKit.
            ModelInfo(id: "parakeet-tdt-v3", kind: .asr,
                      displayName: "Parakeet TDT v3 (multilingual)",
                      repo: "parakeet-tdt-0.6b-v3",
                      approxSizeGB: 0.7, minRAMGB: 8, tier: .balanced),
            ModelInfo(id: "whisper-large-v3-turbo", kind: .asr,
                      displayName: "Whisper large-v3-turbo",
                      repo: "openai_whisper-large-v3-v20240930_turbo",
                      approxSizeGB: 0.6, minRAMGB: 8, tier: .balanced),
            ModelInfo(id: "whisper-small", kind: .asr,
                      displayName: "Whisper small",
                      repo: "openai_whisper-small",
                      approxSizeGB: 0.5, minRAMGB: 8, tier: .fast),
            ModelInfo(id: "whisper-base", kind: .asr,
                      displayName: "Whisper base (отладка)",
                      repo: "openai_whisper-base",
                      approxSizeGB: 0.15, minRAMGB: 8, tier: .fast)
        ],
        llm: [
            ModelInfo(id: "qwen3-4b-4bit", kind: .llm,
                      displayName: "Qwen3 4B (4-bit)",
                      repo: "mlx-community/Qwen3-4B-4bit",
                      approxSizeGB: 2.5, minRAMGB: 8, tier: .fast),
            ModelInfo(id: "qwen3-8b-4bit", kind: .llm,
                      displayName: "Qwen3 8B (4-bit)",
                      repo: "mlx-community/Qwen3-8B-4bit",
                      approxSizeGB: 5, minRAMGB: 24, tier: .balanced),  // 24 — комфортно рядом с Whisper
            ModelInfo(id: "llama3.2-3b-4bit", kind: .llm,
                      displayName: "Llama 3.2 3B (4-bit)",
                      repo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                      approxSizeGB: 2, minRAMGB: 8, tier: .fast)
        ]
    )
}
