import Foundation

/// Движок персонального контекста (RAG): хранит профиль, считает эмбеддинги,
/// достаёт топ-K релевантных кусков под запрос.
public protocol ContextProviding: Sendable {
    /// Прогрев: предрасчёт эмбеддингов профиля (кэшируются один раз).
    func warmUp() async
    /// Топ-K релевантных кусков для запроса (поиск по косинусной близости).
    func topK(for query: String, k: Int) async -> [ContextSnippet]
    /// Освобождение embedding-модели.
    func unload() async
}

public extension ContextProviding {
    func unload() async {}
}

/// Фейковый контекст: возвращает заранее заданные куски профиля. В фазе 6 заменяется
/// на реальный `ContextEngine` с локальной embedding-моделью и поиском по близости.
public struct FakeContextEngine: ContextProviding {
    public init() {}

    public func warmUp() async {}

    public func topK(for query: String, k: Int) async -> [ContextSnippet] {
        let snippets = [
            ContextSnippet(text: "Опыт: 5 лет iOS, Swift, UIKit и SwiftUI, Core ML.",
                           score: 0.91, sourceTitle: "Резюме"),
            ContextSnippet(text: "Проект: офлайн-распознавание речи на устройстве через Core ML и ANE.",
                           score: 0.84, sourceTitle: "Проекты"),
            ContextSnippet(text: "STAR-история: нашёл и починил гонку данных, перейдя на actor-изоляцию.",
                           score: 0.77, sourceTitle: "STAR"),
            ContextSnippet(text: "Сильные стороны: производительность, многопоточность, профилирование Instruments.",
                           score: 0.69, sourceTitle: "Сильные стороны")
        ]
        return Array(snippets.prefix(max(0, k)))
    }
}
