import Foundation

/// Эмбеддер текста: превращает строки в векторы для поиска по близости.
/// За протоколом — локальная модель (MLXEmbedders) или фейк в тестах.
public protocol TextEmbedder: Sendable {
    /// Прогрев: загрузка embedding-модели.
    func warmUp() async throws
    /// Векторы для набора текстов (батч).
    func embed(_ texts: [String]) async throws -> [[Float]]
    /// Освобождение модели.
    func unload() async
}

public extension TextEmbedder {
    func warmUp() async throws {}
    func unload() async {}

    /// Вектор одного текста.
    func embed(_ text: String) async throws -> [Float] {
        try await embed([text]).first ?? []
    }
}
