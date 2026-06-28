import Foundation

/// Фаза разбора экрана.
public enum ScreenAssistPhase: String, Sendable, Equatable {
    case idle
    case capturing   // захват экрана + OCR
    case thinking    // генерация решения LLM
    case done
    case failed
}

/// События разбора экрана наружу (в UI) — единый асинхронный поток, как у сессии.
public enum ScreenAssistEvent: Sendable {
    case stateChanged(ScreenAssistPhase)
    case recognizedText(String)
    case solutionStarted
    case solutionToken(String)
    case solutionCompleted(String)
    case failure(String)
}

/// Состояние разбора экрана для UI — чистый редьюсер событий (тестируемый без UI).
public struct ScreenAssistState: Sendable, Equatable {
    public var phase: ScreenAssistPhase = .idle
    public var recognizedText: String = ""
    public var solution: String = ""
    public var lastError: String?

    public init() {}

    public var isRunning: Bool { phase == .capturing || phase == .thinking }

    public mutating func apply(_ event: ScreenAssistEvent) {
        switch event {
        case .stateChanged(let newPhase):
            phase = newPhase
            if newPhase == .capturing {
                recognizedText = ""
                solution = ""
                lastError = nil
            }
        case .recognizedText(let text):
            recognizedText = text
        case .solutionStarted:
            solution = ""
        case .solutionToken(let token):
            solution += token
        case .solutionCompleted(let full):
            solution = full
        case .failure(let message):
            lastError = message
        }
    }
}
