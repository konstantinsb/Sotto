import Foundation

/// Распознанный текст с экрана. `Sendable` (только строка) — переносится между
/// актёрами без `CGImage`, поэтому картинка не пересекает границы изоляции.
public struct RecognizedScreen: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Источник текста с экрана: внутри захватывает экран и распознаёт текст (OCR),
/// наружу отдаёт только строку. За протоколом — `VisionScreenTextSource` (ScreenCaptureKit
/// + Vision). Замена реализации не трогает оркестратор; в тестах — фейк.
public protocol ScreenTextSource: Sendable {
    /// Захватить экран и распознать текст. `region == nil` — весь активный дисплей (прежнее
    /// поведение); иначе — только выбранная прямоугольная область (прицельный захват, как
    /// Cmd+Shift+4) — меньше OCR-шума и никаких допущений о порядке окон.
    func recognizeScreenText(region: CaptureRegion?) async throws -> RecognizedScreen
}

public extension ScreenTextSource {
    /// Удобный вызов «весь экран» — для существующих мест и тестов.
    func recognizeScreenText() async throws -> RecognizedScreen {
        try await recognizeScreenText(region: nil)
    }
}

/// Ошибки источника текста с экрана.
public enum ScreenTextSourceError: Error, LocalizedError {
    case permissionDenied
    case noDisplay
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Нет доступа к записи экрана. Разреши в Системных настройках → Конфиденциальность и безопасность → Запись экрана, затем перезапусти Sotto."
        case .noDisplay: return "Не найден дисплей для захвата"
        case .captureFailed(let message): return "Не удалось захватить экран — \(message)"
        }
    }
}

/// Фейковый источник: отдаёт заранее заданный текст (тесты и демо без реального экрана).
public struct FakeScreenTextSource: ScreenTextSource {
    private let text: String
    private let delay: Duration

    public init(
        text: String = "Задача: дан массив целых чисел nums и число target. Верните индексы двух чисел, дающих в сумме target.",
        delay: Duration = .milliseconds(1)
    ) {
        self.text = text
        self.delay = delay
    }

    public func recognizeScreenText(region: CaptureRegion?) async throws -> RecognizedScreen {
        // Фейк не захватывает реальный экран — область игнорируется (логика выбора области
        // покрыта чистыми тестами `displayRelativeTopLeftRect`/`pixelRect`).
        try? await Task.sleep(for: delay)
        return RecognizedScreen(text: text)
    }
}
