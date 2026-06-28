import Foundation

/// Текущий выбор моделей пользователем. Персистится приложением (UserDefaults),
/// движки читают его при старте сессии. Смена — в Settings, не в коде.
public struct ModelSelection: Sendable, Equatable, Codable {
    public var asrModelID: String
    public var llmModelID: String

    public init(asrModelID: String, llmModelID: String) {
        self.asrModelID = asrModelID
        self.llmModelID = llmModelID
    }

    public static let `default` = ModelSelection(
        asrModelID: "parakeet-tdt-v3",  // RNN-T без 30-сек паддинга, single-pass по сегменту → успевает за реалтаймом
        llmModelID: "qwen3-4b-4bit"
    )

    /// Дефолт под конкретное устройство: ASR оставляем Parakeet (быстрый, ANE), LLM
    /// подбираем по памяти (на слабом железе — меньше и быстрее). Применять только на
    /// первом запуске (когда пользователь ещё ничего не выбрал) — явный выбор не трогаем.
    public static func recommended(for device: DeviceCapabilities, registry: ModelRegistry) -> ModelSelection {
        ModelSelection(
            asrModelID: ModelSelection.default.asrModelID,
            llmModelID: registry.recommendedLLMID(for: device)
        ).validated(against: registry)
    }

    /// Привести выбор к валидному: если id отсутствует в реестре ИЛИ не того типа
    /// (например, в ASR-слоте оказался LLM-id) — подставить дефолт.
    public func validated(against registry: ModelRegistry) -> ModelSelection {
        ModelSelection(
            asrModelID: registry.info(id: asrModelID, kind: .asr)?.id ?? ModelSelection.default.asrModelID,
            llmModelID: registry.info(id: llmModelID, kind: .llm)?.id ?? ModelSelection.default.llmModelID
        )
    }
}
