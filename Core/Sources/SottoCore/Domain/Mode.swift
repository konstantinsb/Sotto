import Foundation

/// Сценарные режимы ассистента. Реализуем по приоритету: сначала тренировочные интервью.
public enum ModeKind: String, CaseIterable, Sendable, Codable {
    case iosInterview
    case backendInterview
    case systemDesignInterview
    case behavioralInterview
    case salesCall
    case customerSupport
    case meetingSummarizer
    case englishCoach

    /// Человекочитаемое название режима для UI.
    public var title: String {
        switch self {
        case .iosInterview: return "iOS-интервью"
        case .backendInterview: return "Backend-интервью"
        case .systemDesignInterview: return "System Design"
        case .behavioralInterview: return "Behavioral"
        case .salesCall: return "Звонок-продажа"
        case .customerSupport: return "Поддержка клиентов"
        case .meetingSummarizer: return "Саммари встречи"
        case .englishCoach: return "Коуч английского"
        }
    }
}
