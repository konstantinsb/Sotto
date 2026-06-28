import XCTest
@testable import SottoCore

final class PromptBuilderTests: XCTestCase {

    private func snippet(_ text: String, _ score: Double) -> ContextSnippet {
        ContextSnippet(text: text, score: score, sourceTitle: "test")
    }

    func testLimitsContextToTopK() {
        let builder = PromptBuilder(maxContextSnippets: 2, maxContextChars: 10_000)
        let context = [
            snippet("низкая релевантность", 0.10),
            snippet("самая релевантная", 0.90),
            snippet("средняя релевантность", 0.50)
        ]
        let prompt = builder.build(
            mode: .iosInterview,
            systemPrompt: "system",
            profileSummary: nil,
            context: context,
            question: "Как работает ARC?"
        )
        XCTAssertTrue(prompt.user.contains("самая релевантная"))
        XCTAssertTrue(prompt.user.contains("средняя релевантность"))
        XCTAssertFalse(prompt.user.contains("низкая релевантность"))   // отброшена за пределами топ-K
    }

    func testIncludesQuestionAndSystemPrompt() {
        let builder = PromptBuilder()
        let prompt = builder.build(
            mode: .backendInterview,
            systemPrompt: "Ты backend-помощник",
            profileSummary: "5 лет опыта",
            context: [],
            question: "Что такое идемпотентность?"
        )
        XCTAssertEqual(prompt.system, "Ты backend-помощник")
        XCTAssertTrue(prompt.user.contains("Что такое идемпотентность?"))
        XCTAssertTrue(prompt.user.contains("5 лет опыта"))
    }

    func testOmitsEmptyProfile() {
        let builder = PromptBuilder()
        let prompt = builder.build(
            mode: .iosInterview,
            systemPrompt: "system",
            profileSummary: "   ",
            context: [],
            question: "Вопрос?"
        )
        XCTAssertFalse(prompt.user.contains("Профиль кандидата"))
    }

    func testGlossaryCorrectsQuestionAndAddsTermBlock() {
        let builder = PromptBuilder(glossary: .iosDefault)
        let prompt = builder.build(
            mode: .iosInterview,
            systemPrompt: "system",
            profileSummary: nil,
            context: [],
            question: "Чем отличается Асинка Вайт от GCD?"
        )
        XCTAssertTrue(prompt.user.contains("async/await"))        // искажение поправлено
        XCTAssertFalse(prompt.user.contains("Асинка Вайт"))
        XCTAssertTrue(prompt.user.contains("Технические термины"))  // блок глоссария добавлен
    }

    func testNoGlossaryLeavesQuestionUntouched() {
        let builder = PromptBuilder()   // glossary == nil
        let prompt = builder.build(
            mode: .iosInterview,
            systemPrompt: "system",
            profileSummary: nil,
            context: [],
            question: "Чем отличается Асинка Вайт от GCD?"
        )
        XCTAssertTrue(prompt.user.contains("Асинка Вайт"))        // не тронуто
        XCTAssertFalse(prompt.user.contains("Технические термины"))
    }

    func testIncludesScreenTextBeforeQuestion() {
        let builder = PromptBuilder()
        let prompt = builder.build(
            mode: .iosInterview,
            systemPrompt: "system",
            profileSummary: nil,
            context: [],
            question: "Что выведется в консоль?",
            screenText: "let x = [1, 2, 3]\nprint(x.count)"
        )
        guard let screenRange = prompt.user.range(of: "На экране (OCR):"),
              let questionRange = prompt.user.range(of: "Что выведется в консоль?") else {
            return XCTFail("оба блока должны присутствовать в user-промпте")
        }
        XCTAssertTrue(prompt.user.contains("print(x.count)"))
        XCTAssertLessThan(screenRange.lowerBound, questionRange.lowerBound,
                          "секция экрана должна идти ПЕРЕД блоком вопроса")
    }

    func testOmitsScreenSectionWhenNilOrEmpty() {
        let builder = PromptBuilder()
        let promptNil = builder.build(
            mode: .iosInterview, systemPrompt: "system", profileSummary: nil,
            context: [], question: "Вопрос?", screenText: nil
        )
        XCTAssertFalse(promptNil.user.contains("На экране (OCR)"))

        // Пустой/пробельный экран после очистки не порождает секцию.
        let promptEmpty = builder.build(
            mode: .iosInterview, systemPrompt: "system", profileSummary: nil,
            context: [], question: "Вопрос?", screenText: "   \n\n  \n"
        )
        XCTAssertFalse(promptEmpty.user.contains("На экране (OCR)"))
    }

    func testTruncatesScreenTextByMaxScreenChars() {
        let builder = PromptBuilder(maxScreenChars: 50)
        let long = String(repeating: "x", count: 5_000)
        let prompt = builder.build(
            mode: .iosInterview, systemPrompt: "system", profileSummary: nil,
            context: [], question: "Вопрос?", screenText: long
        )
        XCTAssertTrue(prompt.user.contains("На экране (OCR)"))
        // Сырой длинный фрагмент не должен пролезть целиком (обрезан до лимита).
        XCTAssertFalse(prompt.user.contains(String(repeating: "x", count: 100)))
    }

    func testTruncatesContextByChars() {
        let builder = PromptBuilder(maxContextSnippets: 4, maxContextChars: 30)
        let context = [snippet(String(repeating: "x", count: 500), 0.9)]
        let prompt = builder.build(
            mode: .iosInterview,
            systemPrompt: "system",
            profileSummary: nil,
            context: context,
            question: "Вопрос?"
        )
        // Блок контекста обрезан, но вопрос (отдельная секция) присутствует.
        XCTAssertTrue(prompt.user.contains("Вопрос?"))
        XCTAssertFalse(prompt.user.contains(String(repeating: "x", count: 100)))
    }
}
