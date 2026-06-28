import Foundation

/// Параметры генерации, управляющие задержкой и формой ответа. Прокидываются от
/// оркестратора к движку (`MLXEngine`/`CloudLLMEngine`); фейки их игнорируют.
///
/// Зачем: раньше длина ответа была не ограничена (`maxTokens = nil`) — хвост latency
/// непредсказуем, модель «растекается». Здесь задаём предел длины и режим сэмплирования
/// под сценарий. `temperature == 0` → жадное (greedy) декодирование: детерминированно
/// и чуть быстрее (argmax вместо категориального сэмплера).
public struct GenerationOptions: Sendable, Equatable {
    /// Жёсткий предел длины ответа в токенах. `nil` — без ограничения (как было).
    public var maxTokens: Int?
    /// Температура сэмплирования. 0 — жадный argmax (детерминированно, быстрее).
    public var temperature: Float

    public init(maxTokens: Int? = nil, temperature: Float = 0.6) {
        self.maxTokens = maxTokens.map { max(1, $0) }
        self.temperature = max(0, temperature)
    }

    /// Поведение по умолчанию движка (без ограничений) — для обратной совместимости.
    public static let unbounded = GenerationOptions()

    /// Живая подсказка: ограничиваем хвост latency, но даём достаточно длины для полноценного
    /// ответа на суть вопроса. Лёгкая температура (не чистый greedy) — формулировки живее.
    public static let liveHint = GenerationOptions(maxTokens: 350, temperature: 0.4)

    /// Summary разговора: длиннее, чуть живее формулировки.
    public static let summary = GenerationOptions(maxTokens: 700, temperature: 0.3)

    /// Разбор экрана (код-ответ может быть длиннее подсказки), детерминированно.
    public static let screenAssist = GenerationOptions(maxTokens: 512, temperature: 0)

    /// Параметры под режим. Коуч английского оставляем с лёгкой вариативностью — для
    /// естественности фраз; саммари-режим чуть длиннее; остальные — кратко и детерминированно.
    public static func forMode(_ mode: ModeKind) -> GenerationOptions {
        switch mode {
        case .englishCoach:
            return GenerationOptions(maxTokens: 220, temperature: 0.5)
        case .meetingSummarizer:
            return GenerationOptions(maxTokens: 320, temperature: 0.2)
        default:
            return .liveHint
        }
    }
}
