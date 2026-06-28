import Foundation

/// Профиль пользователя для персонального контекста (RAG). В фазе 6 — несколько
/// текстовых секций; в фазе 9 переедет в SwiftData с документами и эмбеддингами.
public struct UserProfile: Sendable, Codable, Equatable {
    public var about: String        // о себе / опыт
    public var projects: String     // проекты
    public var stack: String        // стек / технологии
    public var starStories: String  // STAR-истории

    public init(about: String = "", projects: String = "", stack: String = "", starStories: String = "") {
        self.about = about
        self.projects = projects
        self.stack = stack
        self.starStories = starStories
    }

    public var isEmpty: Bool {
        sources.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Источники для чанкования: (заголовок секции, текст).
    public var sources: [(title: String, text: String)] {
        [
            ("Опыт", about),
            ("Проекты", projects),
            ("Стек", stack),
            ("STAR-истории", starStories)
        ]
    }

    /// Краткая сводка для подстановки в промпт (SessionConfiguration.profileSummary).
    public var summary: String {
        sources
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.title): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Сводка для ПОСТОЯННОЙ подстановки в промпт (always-on контекст уходит в каждый
    /// запрос — без кэпа большой профиль раздувал бы каждую генерацию и латентность).
    /// Берёт все непустые секции (раньше слался только `about.prefix(240)`, и проекты/
    /// стек/STAR-истории до промпта не доезжали), но обрезает по символам.
    public func promptSummary(maxChars: Int = 700) -> String {
        String(summary.prefix(max(0, maxChars)))
    }
}
