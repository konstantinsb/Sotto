import Foundation

/// Собранный промпт: системная часть (режим) + пользовательская (профиль+контекст+вопрос).
public struct Prompt: Sendable, Equatable {
    public let system: String
    public let user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// Ошибки движка генерации, пробрасываемые через поток `generate`.
public enum LLMEngineError: Error, LocalizedError {
    /// Модель не загружена (сбой прогрева/скачивания) — генерация невозможна.
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Модель генерации не загружена"
        }
    }
}

/// Движок генерации.
///
/// За этим протоколом в фазе 4 встанет `MLXEngine` (Metal, unified memory, потоковый
/// вывод токенов). Замена на llama.cpp не затронет оркестратор и UI.
public protocol LLMEngine: Sendable {
    var modelName: String { get }
    /// Прогрев: загрузка модели и холостой инференс (компиляция Metal-ядер).
    func warmUp() async
    /// Потоковая генерация: куски текста (слова/токены) по мере готовности.
    /// `options` управляет пределом длины и режимом сэмплирования (см. `GenerationOptions`).
    /// Поток бросает, если генерация сорвалась (например, модель не загрузилась) —
    /// потребитель отличает реальный сбой от просто пустого ответа.
    func generate(prompt: Prompt, options: GenerationOptions) -> AsyncThrowingStream<String, Error>
    /// Выгрузка модели и освобождение памяти. По умолчанию — ничего (для фейков).
    func unload() async
}

public extension LLMEngine {
    func unload() async {}

    /// Удобный вызов без явных параметров — поведение движка по умолчанию (без ограничений).
    /// Сохраняет совместимость со старыми вызовами `generate(prompt:)`.
    func generate(prompt: Prompt) -> AsyncThrowingStream<String, Error> {
        generate(prompt: prompt, options: .unbounded)
    }
}
