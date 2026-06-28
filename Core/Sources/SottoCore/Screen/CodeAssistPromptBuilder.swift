import Foundation

/// Вид задания, распознанный в разборе экрана. Под каждый вид — своя инструкция в
/// системном промпте (а не одно общее «сначала определи тип»), чтобы «улучши/перепиши»
/// не проваливалось в ветку «реши», а алгозадача не получала iOS-рантайм-оптику.
public enum TaskKind: Sendable {
    /// «Что выведется в консоль» — нужен точный вывод построчно.
    case output
    /// Исправить/найти баг/реализовать по условию — универсальная ветка.
    case solve
    /// Улучшить/переписать/оптимизировать структуру кода.
    case refactor
    /// Алгозадача: идея алгоритма + асимптотика по времени и памяти.
    case algorithm
}

/// Сборка промпта «реши задачу с экрана»: системная роль ассистента на собеседовании +
/// распознанный текст экрана (+ короткий профиль). Длину экрана ограничиваем, чтобы
/// промпт оставался компактным (top-K-подобная обрезка контекста).
public struct CodeAssistPromptBuilder: Sendable {
    public var maxScreenChars: Int

    public init(maxScreenChars: Int = 4000) {
        self.maxScreenChars = max(500, maxScreenChars)
    }

    /// Чистая (без побочных эффектов) эвристика типа задания.
    ///
    /// Приоритет источников: СНАЧАЛА устный вопрос интервьюера (живой сигнал, что именно
    /// спросили), затем — текст экрана (OCR). Внутри одного источника проверяем виды в
    /// порядке: output → refactor → solve → algorithm; первое совпадение и побеждает.
    /// solve проверяется РАНЬШЕ algorithm специально: «исправь баг в алгоритме» — это solve,
    /// а не алгозадача (иначе общий ключ «алгоритм» уводил бы баг-фиксы в неверную ветку).
    /// Если ни один источник не дал совпадения — дефолт `.solve` (самая универсальная
    /// ветка: подойдёт и под «реализуй», и под «найди баг»). Сравнение регистронезависимое.
    public static func inferTaskKind(screenText: String, spokenQuestion: String) -> TaskKind {
        // Сначала пытаемся определить по устному вопросу — он главнее экрана.
        if let kind = match(in: spokenQuestion) { return kind }
        if let kind = match(in: screenText) { return kind }
        return .solve
    }

    /// Ключевые слова по видам (рус+англ). Порядок проверки фиксирован:
    /// output → refactor → solve → algorithm. Возвращает nil, если ничего не сматчилось.
    private static func match(in raw: String) -> TaskKind? {
        let text = raw.lowercased()
        guard !text.isEmpty else { return nil }
        func has(_ keys: [String]) -> Bool { keys.contains { text.contains($0) } }

        // Подстроки нарочно «корневые» («что вывед» ловит выведется/выведет/выведет код;
        // «что вернёт» — без обязательного «консоль»), т.к. это самые частые устные формы
        // вопроса про вывод, а именно output-ветка несёт анти-галлюцинацию по адресам/тредам.
        let outputKeys = ["что вывед", "что напечат", "что вернёт",
                          "output", "prints", "console"]
        let refactorKeys = ["отрефактори", "улучши", "перепиши", "оптимизируй", "почисти",
                            "refactor", "clean up", "improve"]
        let solveKeys = ["найди баг", "исправь", "почему падает", "не работает",
                        "fix", "bug", "реализуй", "дебаг", "отладь"]
        let algorithmKeys = ["сложность", "big o", "o(n)", "напиши алгоритм", "реши задачу",
                            "leetcode", "алгоритм", "complexity"]

        if has(outputKeys) { return .output }
        if has(refactorKeys) { return .refactor }
        if has(solveKeys) { return .solve }
        if has(algorithmKeys) { return .algorithm }
        return nil
    }

    public func build(screenText: String, profileSummary: String = "", spokenQuestion: String = "") -> Prompt {
        let kind = Self.inferTaskKind(screenText: screenText, spokenQuestion: spokenQuestion)

        // Системная iOS/Swift-рамка + язык ответа — общие для всех видов (вне scope 2.2).
        let frame = """
        Ты — ассистент кандидата на iOS/Swift-собеседовании. На вход — текст, распознанный OCR с \
        экрана интервьюера (обычно Swift-плейграунд; возможны ошибки OCR — восстанавливай смысл кода).
        """
        let closing = "Отвечай по-русски, кратко, чтобы это можно было проговорить вслух. Идентификаторы и код — в оригинале."

        // Инструкция под конкретный вид задания (вместо общего «сначала определи тип»).
        let task: String
        switch kind {
        case .output:
            task = """
            Тип задания: ЧТО ВЫВЕДЕТСЯ В КОНСОЛЬ. Дай ТОЧНЫЙ вывод построчно, затем 1–2 фразы \
            почему (identity ссылок, ARC/retain, value- vs reference-семантика, COW, тип \
            диспетчеризации, главный/фоновый тред, порядок deinit, число перерасчётов body в SwiftUI).

            ВАЖНО — не выдумывай недетерминированное:
            • Конкретные адреса памяти (0x…) и номера/имена тредов от запуска к запуску РАЗНЫЕ — НЕ \
            сочиняй их. Описывай ПОВЕДЕНИЕ: «эти два адреса одинаковые → та же ссылка; третий \
            отличается → буфер переаллоцирован при росте», «не главный тред», «main».
            • Если вывод зависит от среды/гонки — так и скажи.
            """
        case .solve:
            task = """
            Тип задания: РЕШИТЬ ЗАДАЧУ / НАЙТИ БАГ. Кратко: суть задачи, ключевая идея решения или \
            где именно баг, при необходимости — компактный исправленный фрагмент кода.
            """
        case .refactor:
            task = """
            Тип задания: УЛУЧШИТЬ / ПЕРЕПИСАТЬ КОД. Сначала назови, что улучшить (читаемость, \
            сложность, идиоматичность Swift), затем дай компактный переписанный фрагмент и 1 фразу, \
            почему так лучше.
            """
        case .algorithm:
            task = """
            Тип задания: АЛГОЗАДАЧА. Дай идею алгоритма, асимптотику O(...) по времени и по памяти, \
            компактный код и ключевые edge-cases.
            """
        }

        let system = [frame, task, closing].joined(separator: "\n\n")

        // Сжимаем OCR ДО обрезки по лимиту: убираем шум (пустые строки, висячие пробелы,
        // одиночные символы-артефакты) — так под тот же лимит символов влезает больше
        // полезного текста и короче префилл (меньше задержка до первого токена).
        let screen = String(Self.compact(screenText).prefix(maxScreenChars))
        var user = ""
        if !profileSummary.isEmpty {
            user += "Профиль кандидата: \(profileSummary)\n\n"
        }
        // Вопрос интервьюера — главный сигнал типа задания (что именно спросили вслух),
        // поэтому ставим его РАНЬШЕ экрана: OCR угадывает тип по ключевым словам, а живой
        // вопрос задаёт его прямо.
        let question = spokenQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty {
            user += "Вопрос интервьюера вслух: \(question)\n\n"
        }
        user += "=== Экран (OCR) ===\n\(screen)\n=== Конец экрана ==="

        return Prompt(system: system, user: user)
    }

    /// Структурно значимые в коде одиночные символы — их НЕЛЬЗЯ выбрасывать как «мусор»
    /// (иначе из кода пропадают строки-скобки `}`/`{`/`)` и ломается разбор).
    private static let codePunctuation: Set<Character> = ["{", "}", "(", ")", "[", "]"]

    /// Убрать OCR-шум: для каждой строки схлопнуть внутренние пробелы и обрезать края;
    /// выбросить пустые и «мусорные» строки (один символ, не буква/цифра и НЕ код-скобка).
    /// Пустые строки между блоками не плодим — это экономит токены без потери смысла.
    static func compact(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.count == 1, let ch = line.first,
                   !ch.isLetter, !ch.isNumber, !codePunctuation.contains(ch) { return false }
                return true
            }
            .joined(separator: "\n")
    }
}
