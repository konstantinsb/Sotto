import Foundation

/// Сборка промпта под режим. Ограничивает длину: топ-K чанков контекста и грубая
/// обрезка по символам, чтобы не переполнять контекст модели.
public struct PromptBuilder: Sendable {
    public let maxContextSnippets: Int
    public let maxContextChars: Int
    /// Предел длины OCR-текста экрана (символов): грубая обрезка, чтобы код на экране
    /// не вытеснял вопрос и не переполнял контекст модели.
    public let maxScreenChars: Int
    /// Глоссарий терминов: детерминированно чинит искажения в вопросе и даёт модели
    /// канонический словарь. `nil` — без глоссария (поведение по умолчанию для тестов).
    public let glossary: TermGlossary?

    public init(maxContextSnippets: Int = 4, maxContextChars: Int = 1500, maxScreenChars: Int = 2000, glossary: TermGlossary? = nil) {
        self.maxContextSnippets = maxContextSnippets
        self.maxContextChars = maxContextChars
        self.maxScreenChars = maxScreenChars
        self.glossary = glossary
    }

    public func build(
        mode: ModeKind,
        systemPrompt: String,
        profileSummary: String?,
        context: [ContextSnippet],
        question: String,
        screenText: String? = nil
    ) -> Prompt {
        var sections: [String] = []

        if let profile = profileSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !profile.isEmpty {
            sections.append("Профиль кандидата:\n\(profile)")
        }

        let topSnippets = context
            .sorted { $0.score > $1.score }
            .prefix(maxContextSnippets)
        if !topSnippets.isEmpty {
            var block = "Релевантный контекст:\n"
            for snippet in topSnippets {
                block += "- \(snippet.text)\n"
            }
            sections.append(String(block.prefix(maxContextChars)))
        }

        // Глоссарий: сначала детерминированно чиним заведомые искажения в вопросе, затем
        // (если есть) даём модели канонический словарь для остаточных искажений.
        let resolvedQuestion = glossary?.correct(question) ?? question
        if let block = glossary?.promptBlock(), !block.isEmpty {
            sections.append(block)
        }

        // Код/текст с экрана (OCR): вставляем ПЕРЕД блоком вопроса, чтобы answerDirective
        // остался последним recency-якорем. Чистим локально и независимо (не завязываемся
        // на CodeAssistPromptBuilder), затем грубо обрезаем по maxScreenChars.
        if let cleaned = Self.cleanScreenText(screenText, limit: maxScreenChars) {
            sections.append("На экране (OCR):\n\(cleaned)")
        }

        // Вопрос распознан с речи: англоязычные технические термины часто искажаются
        // («Эйсинка Вайт» = async/await, «существо/Свойфтюай» = SwiftUI, «АРС» = ARC,
        // «ретайн цикл» = retain cycle, «коррета» = Core Data). Просим модель восстановить
        // их по смыслу и не выдумывать несуществующих сущностей (наблюдали «ARC = Apple
        // Reality SDK», ответ про «инкапсуляцию» вместо async/await).
        sections.append("""
        Вопрос собеседника (распознан с речи — англоязычные технические термины могли \
        исказиться; восстанови их по смыслу из контекста iOS/Swift, не выдумывай несуществующих \
        понятий):
        \(resolvedQuestion)
        """)
        sections.append(Self.answerDirective(for: mode))   // форма/язык ответа — последним (recency-якорь)

        return Prompt(system: systemPrompt, user: sections.joined(separator: "\n\n"))
    }

    /// Локальная очистка OCR-текста экрана: трим каждой строки, выброс пустых строк,
    /// грубая обрезка до `limit` символов. Возвращает `nil`, если на входе nil/пусто или
    /// после очистки ничего не осталось (тогда секции «На экране (OCR)» не будет).
    static func cleanScreenText(_ raw: String?, limit: Int) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(limit))
    }

    /// Закрепляет ФОРМУ и язык ответа (recency-якорь в конце промпта). Цель — живая устная
    /// реплика, которую кандидат проговаривает, а не зачитывает: иначе по «буллет-листу из
    /// LLM» собеседник сразу понимает, что ответ читают. Язык фиксируем жёстко — модель
    /// изредка срывается на другой (наблюдали китайский в подсказке).
    private static func answerDirective(for mode: ModeKind) -> String {
        switch mode {
        case .englishCoach:
            return "Reply ONLY in English, the way you'd actually say it out loud: first person, natural and conversational, 2–4 short sentences. No lists, headings, bullet points or markdown — this is a spoken line, not notes. Get straight to the point. Do not use any other language."
        case .meetingSummarizer:
            return "Пиши по-русски, кратко и по делу: суть, решения, задачи, договорённости. Допустимы короткие пункты. Не используй другие языки."
        default:
            return "Отвечай так, как сказал бы это вслух на собеседовании: по-русски, от первого лица, разговорно и по-человечески, 2–4 коротких предложения. Без списков, заголовков, маркеров и markdown — это устная реплика, а не конспект. Сразу по сути, без воды. Не используй другие языки."
        }
    }
}
