import Foundation

/// Состояние сессии. Главный поток рисует UI по смене состояния.
public enum SessionState: String, Sendable, Equatable {
    case idle        // не запущена
    case warmingUp   // прогрев моделей (компиляция Metal-ядер)
    case listening   // слушаем и расшифровываем
    case thinking    // генерируем подсказку
    case failed      // фатальный сбой (модель/разрешение) — терминальное состояние

    public var title: String {
        switch self {
        case .idle: return "Ожидание"
        case .warmingUp: return "Прогрев…"
        case .listening: return "Слушаю"
        case .thinking: return "Думаю…"
        case .failed: return "Ошибка"
        }
    }
}

/// Единый поток событий сессии наружу (в UI). Оркестратор только публикует события,
/// UI только потребляет — связь между слоями исключительно через этот асинхронный поток.
public enum SessionEvent: Sendable {
    case stateChanged(SessionState)
    case transcript(TranscriptEvent)
    case questionDetected(DetectedQuestion)
    case suggestionStarted(id: UUID)
    case suggestionToken(id: UUID, token: String)
    case suggestionCompleted(Suggestion)
    case failure(String)
}
