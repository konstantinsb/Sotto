import Foundation

/// Конфигурация одной сессии: режим, системный промпт, краткий профиль и K для RAG.
public struct SessionConfiguration: Sendable {
    public var mode: ModeKind
    public var systemPrompt: String
    public var profileSummary: String?
    public var topK: Int
    /// Параметры генерации (предел длины/температура). По умолчанию — под режим.
    public var generationOptions: GenerationOptions
    /// Доставать ли персональный контекст (RAG) перед генерацией. `false` — режим низкой
    /// задержки: пропускаем эмбеддинг запроса и опираемся только на `profileSummary`.
    public var useContextRetrieval: Bool
    /// Спекулятивно стартовать ответ на частичной (ещё не зафиксированной) расшифровке,
    /// как только она выглядит завершённым вопросом — убирает «налог на тишину» (~1.3 c
    /// ожидания финала). На финале результат сверяется и не дублируется.
    public var speculateOnPartials: Bool
    /// Минимальный интервал между ДВУМЯ спекулятивными стартами. ASR перетранскрибирует
    /// растущее окно каждые ~0.4 c, дёргая текст/пунктуацию — без ограничения каждый партиал
    /// слал бы новый облачный запрос и упирался в лимит провайдера (RPM). Первый старт нового
    /// вопроса не задерживается (счётчик сбрасывается на финале) — троттлятся лишь повторы.
    /// `.zero` — троттлинг выключен.
    public var speculationCooldown: Duration

    public init(
        mode: ModeKind,
        systemPrompt: String,
        profileSummary: String? = nil,
        topK: Int = 4,
        generationOptions: GenerationOptions? = nil,
        useContextRetrieval: Bool = true,
        speculateOnPartials: Bool = true,
        speculationCooldown: Duration = .milliseconds(1200)
    ) {
        self.mode = mode
        self.systemPrompt = systemPrompt
        self.profileSummary = profileSummary
        self.topK = topK
        self.generationOptions = generationOptions ?? .forMode(mode)
        self.useContextRetrieval = useContextRetrieval
        self.speculateOnPartials = speculateOnPartials
        self.speculationCooldown = speculationCooldown
    }
}
