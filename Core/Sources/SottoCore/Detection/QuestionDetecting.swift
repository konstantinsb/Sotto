import Foundation

/// Детектор вопросов: решает, прозвучал ли вопрос (и пора ли будить LLM).
public protocol QuestionDetecting: Sendable {
    /// Возвращает обнаруженный вопрос либо `nil`. Вызывается на зафиксированных сегментах.
    func detect(in segment: TranscriptSegment) -> DetectedQuestion?

    /// Спекулятивная детекция на ЧАСТИЧНОЙ гипотезе (ещё не финал). Должна быть
    /// высокоточной (лучше пропустить, чем сработать на полуфразе), потому что запускает
    /// генерацию до фиксации сегмента. По умолчанию — `nil` (детектор не спекулирует).
    func detectSpeculative(in segment: TranscriptSegment) -> DetectedQuestion?
}

public extension QuestionDetecting {
    func detectSpeculative(in segment: TranscriptSegment) -> DetectedQuestion? { nil }
}

/// Простой эвристический детектор. Финал разбирается ПО ПРЕДЛОЖЕНИЯМ; вопросом считается
/// предложение, которое кончается на «?», начинается с вопросительного слова или содержит
/// частицу «ли». Триггерим, только если есть вопрос «по сути» (не служебная реплика вроде
/// «Понял?», «А как ты?»), а в LLM отдаём ВЕСЬ сегмент (контекст).
/// Источник (микрофон/собеседник) решает оркестратор — детектор чист и тестируем.
public struct HeuristicQuestionDetector: QuestionDetecting {
    private static let questionWords: Set<String> = [
        // ru
        "как", "что", "почему", "зачем", "когда", "где", "кто", "какой", "какая",
        "какие", "сколько", "можете", "можешь", "расскажите", "расскажи",
        "объясните", "объясни", "опишите", "опиши",
        // en
        "how", "what", "why", "when", "where", "who", "which", "can", "could",
        "would", "explain", "describe", "tell"
    ]

    /// Служебные/филлерные слова. Если вопросительное предложение состоит ТОЛЬКО из них —
    /// это реплика-подтверждение («Понял?», «А как ты?», «Так?»), а не вопрос по сути,
    /// и будить LLM не нужно. Включает и вопросительные слова (как/что): сами по себе они
    /// не несут содержания — нужно хотя бы одно «контентное» слово рядом.
    private static let fillerWords: Set<String> = [
        "а", "и", "ну", "так", "вот", "это", "то", "же", "бы", "ли", "не",
        "я", "ты", "вы", "мы", "он", "она", "они",
        "в", "с", "к", "о", "об", "у", "по", "на", "за", "из", "от", "до",
        "да", "нет", "окей", "ок", "итак", "теперь", "ещё", "еще", "уже",
        "понял", "поняла", "понятно", "ясно", "хорошо", "отлично", "готов", "готова",
        "продолжай", "продолжаем", "давай", "давайте", "спасибо", "перебиваю",
        "как", "что"
    ]

    /// Минимум слов в спекулятивном вопросе — отсекает срабатывание на «как?», «что?».
    private let speculativeMinWords: Int

    public init(speculativeMinWords: Int = 3) {
        self.speculativeMinWords = max(1, speculativeMinWords)
    }

    public func detect(in segment: TranscriptSegment) -> DetectedQuestion? {
        guard segment.isFinal else { return nil }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Триггерим, если в сегменте есть хоть одно вопросительное предложение, но в LLM
        // отдаём ВЕСЬ сегмент: суть часто в первом предложении («Как объяснишь разницу
        // value/reference type?»), а последнее вопросительное — лишь уточнение («И почему
        // это принципиально?»). Раньше бралось только последнее — модель отвечала на хвост,
        // теряя суть вопроса.
        guard Self.splitSentences(text).contains(where: Self.isSubstantiveQuestion) else { return nil }
        return DetectedQuestion(segment: segment, question: text)
    }

    /// Спекуляция на частичной гипотезе: срабатывает только на СИЛЬНОМ сигнале завершения —
    /// последнее предложение оканчивается на «?». Растущая полуфраза без «?» не триггерит
    /// (ждём финал), поэтому генерация не перезапускается на каждом слове.
    public func detectSpeculative(in segment: TranscriptSegment) -> DetectedQuestion? {
        guard !segment.isFinal else { return nil }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        guard let last = Self.splitSentences(text).last(where: { $0.hasSuffix("?") }) else { return nil }
        let wordCount = last.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        guard wordCount >= speculativeMinWords, Self.isSubstantiveQuestion(last) else { return nil }
        // Как и в detect: отдаём весь накопленный текст (контекст), а не одно последнее
        // вопросительное предложение — иначе LLM ответит на хвост, теряя суть.
        return DetectedQuestion(segment: segment, question: text)
    }

    /// Разбить на предложения по терминаторам `.?!`, сохраняя пунктуацию.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    static func isQuestion(_ sentence: String) -> Bool {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if s.hasSuffix("?") { return true }
        let words = s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first else { return false }
        if questionWords.contains(first) { return true }   // вопросительное слово в начале предложения
        if words.contains("ли") { return true }            // частица «ли»: «всё ли…», «можно ли…»
        return false
    }

    /// Вопрос «по сути»: это вопрос И в нём есть хотя бы одно содержательное (не служебное)
    /// слово. Отсекает реплики-подтверждения «Понял?», «А как ты?», «Так?», но пропускает
    /// короткие настоящие вопросы вроде «Что такое ARC?» («arc» — содержательное слово).
    static func isSubstantiveQuestion(_ sentence: String) -> Bool {
        guard isQuestion(sentence) else { return false }
        let words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains { !fillerWords.contains($0) }
    }
}
