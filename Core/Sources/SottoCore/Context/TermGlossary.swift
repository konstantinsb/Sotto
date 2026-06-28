import Foundation

/// Одно известное искажение ASR → канон.
public struct TermCorrection: Sendable, Equatable {
    public let garbled: String
    public let canonical: String
    public init(_ garbled: String, _ canonical: String) {
        self.garbled = garbled
        self.canonical = canonical
    }
}

/// Глоссарий технических терминов. Решает две разные задачи восстановления терминов,
/// которые ASR коверкает в русской речи («Асинка Вайт» = async/await, «Коплишн Кложери» =
/// completion closure, «кордета» = Core Data):
///
/// 1. `correct(_:)` — ДЕТЕРМИНИРОВАННО заменяет заведомо «мусорные» варианты на канон.
///    Сюда кладём только характерные несуществующие строки — иначе риск испортить реальное
///    слово. То, что распознано однозначно неправильно, чиним без модели.
/// 2. `promptBlock(...)` — даёт модели канонический словарь, чтобы остаточные искажения она
///    восстанавливала по контексту и писала термины единообразно (английский, не транслит).
///
/// Дополняет, а не заменяет инструкцию в `PromptBuilder` про восстановление терминов.
public struct TermGlossary: Sendable, Equatable {
    /// Канонические написания — модель должна писать термины именно так.
    public let canonicalTerms: [String]
    /// Известные искажения → канон. Ключи — в нижнем регистре.
    public let corrections: [TermCorrection]

    public init(canonicalTerms: [String], corrections: [TermCorrection]) {
        self.canonicalTerms = canonicalTerms
        // Длинные ключи раньше коротких: «коплишн кложери» должно сработать прежде, чем
        // его префикс «коплишн кложер» успеет заменить часть строки.
        self.corrections = corrections.sorted { $0.garbled.count > $1.garbled.count }
    }

    public var isEmpty: Bool { canonicalTerms.isEmpty && corrections.isEmpty }

    /// Детерминированно поправить заведомые искажения в тексте (регистр игнорируется).
    /// Неизвестные фрагменты не трогаются.
    public func correct(_ text: String) -> String {
        guard !corrections.isEmpty, !text.isEmpty else { return text }
        var result = text
        for correction in corrections {
            result = result.replacingOccurrences(
                of: correction.garbled,
                with: correction.canonical,
                options: [.caseInsensitive]
            )
        }
        return result
    }

    /// Компактный однострочный блок канонических терминов для подстановки в промпт.
    /// Пусто, если терминов нет. `maxTerms` ограничивает длину (always-on контекст).
    public func promptBlock(maxTerms: Int = 24) -> String {
        guard !canonicalTerms.isEmpty, maxTerms > 0 else { return "" }
        let terms = canonicalTerms.prefix(maxTerms).joined(separator: ", ")
        return "Технические термины пиши канонично, на английском и без транслита: \(terms)."
    }

    /// Глоссарий под режим: технические интервью получают iOS-словарь, остальные — нет
    /// (для них iOS-термины нерелевантны или вредны). В фазе именованных профилей это
    /// станет настраиваемым per-профиль.
    public static func forMode(_ mode: ModeKind) -> TermGlossary? {
        switch mode {
        case .iosInterview, .systemDesignInterview:
            return .iosDefault
        default:
            return nil
        }
    }

    /// Стартовый iOS/Swift-глоссарий. Канонические термины + характерные искажения,
    /// наблюдавшиеся в `evaluation.txt` (англоязычные термины в русской речи).
    public static let iosDefault = TermGlossary(
        canonicalTerms: [
            "async/await", "Swift Concurrency", "actor", "@MainActor", "Task",
            "completion handler", "escaping closure", "ARC", "retain cycle",
            "strong/weak/unowned reference", "memory leak", "GCD", "DispatchQueue",
            "Combine", "Core Data", "SwiftUI", "UIKit", "Codable", "URLSession",
            "MVVM", "dependency injection", "LazyVStack", "trade-off",
            "thread safety", "data race"
        ],
        corrections: [
            // async/await
            TermCorrection("асинка вайт", "async/await"),
            TermCorrection("эйсинка вайт", "async/await"),
            TermCorrection("асинка вэйт", "async/await"),
            TermCorrection("асинк авайт", "async/await"),
            // completion closure / handler
            TermCorrection("коплишн кложери", "completion closure"),
            TermCorrection("коплешн кложери", "completion closure"),
            TermCorrection("коплишн кложер", "completion closure"),
            TermCorrection("коплишн клори", "completion closure"),
            // retain cycle
            TermCorrection("ретайн цикл", "retain cycle"),
            TermCorrection("ретейн цикл", "retain cycle"),
            // Core Data
            TermCorrection("кордета", "Core Data"),
            TermCorrection("кор-ита", "Core Data"),
            TermCorrection("коррета", "Core Data"),
            // LazyVStack
            TermCorrection("лазервистек", "LazyVStack"),
            TermCorrection("лейзивистек", "LazyVStack"),
            // trade-off
            TermCorrection("крейдофф", "trade-off"),
            TermCorrection("крейдов", "trade-off")
        ]
    )
}
