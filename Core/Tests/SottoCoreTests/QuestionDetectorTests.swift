import XCTest
@testable import SottoCore

final class QuestionDetectorTests: XCTestCase {
    private let detector = HeuristicQuestionDetector()

    private func segment(_ text: String, isFinal: Bool = true) -> TranscriptSegment {
        TranscriptSegment(source: .system, text: text, isFinal: isFinal, start: 0, end: 1)
    }

    func testDetectsByQuestionMark() {
        XCTAssertNotNil(detector.detect(in: segment("Вы знакомы с акторами?")))
    }

    func testDetectsByQuestionWord() {
        XCTAssertNotNil(detector.detect(in: segment("Расскажите про вашу архитектуру")))
        XCTAssertNotNil(detector.detect(in: segment("How would you scale this")))
    }

    func testIgnoresStatement() {
        XCTAssertNil(detector.detect(in: segment("Это был отличный проект")))
    }

    func testIgnoresPartialSegment() {
        XCTAssertNil(detector.detect(in: segment("Вы знакомы с акторами?", isFinal: false)))
    }

    func testIgnoresEmpty() {
        XCTAssertNil(detector.detect(in: segment("   ")))
    }

    // Многопредложенный финал: триггерим по наличию вопроса, но отдаём ВЕСЬ сегмент.
    func testDetectsQuestionMidSegment() {
        let text = "Ну мой вопрос всё ли тут в порядке? Нет, это базовый вопрос, с которого всё начинается."
        let q = detector.detect(in: segment(text))
        XCTAssertEqual(q?.question, text, "в LLM уходит весь сегмент (контекст), не только вопрос")
    }

    func testPassesFullContextNotJustLastQuestion() {
        // Главный баг из реальной сессии: суть в первом предложении, а последнее
        // вопросительное — лишь уточнение. Раньше уходило только уточнение.
        let text = "Как ты объяснишь разницу между value type и reference type? И почему это принципиально?"
        let q = detector.detect(in: segment(text))
        XCTAssertEqual(q?.question, text)
        XCTAssertTrue(q?.question.contains("разницу между value type") ?? false,
                      "суть вопроса не должна теряться")
    }

    func testDetectsWholeSegmentWithSeveralQuestions() {
        let text = "Что такое мутейтинг? Давай разберём. Что происходит на пятой строчке?"
        XCTAssertEqual(detector.detect(in: segment(text))?.question, text)
    }

    func testStatementWithQuestionWordMidSentenceIgnored() {
        // «как» не в начале и нет «?» → не вопрос.
        XCTAssertNil(detector.detect(in: segment("Я покажу как это работает.")))
    }

    // MARK: - Фильтр филлера (служебные реплики не будят LLM)

    func testIgnoresFillerAcknowledgement() {
        XCTAssertNil(detector.detect(in: segment("Понял?")))
        XCTAssertNil(detector.detect(in: segment("А как ты?")))
        XCTAssertNil(detector.detect(in: segment("Так?")))
    }

    func testIgnoresSegmentWhereOnlyQuestionIsFiller() {
        // Единственное вопросительное предложение — филлер; остальное без «?».
        XCTAssertNil(detector.detect(in: segment("Понял? Давай тогда послушаем твой ответ полностью. Продолжай.")))
    }

    func testKeepsShortSubstantiveQuestion() {
        // Короткий, но настоящий вопрос — «arc»/«такое» содержательны.
        XCTAssertNotNil(detector.detect(in: segment("Что такое ARC?")))
    }

    func testFillerBeforeRealQuestionStillTriggersWithFullContext() {
        let text = "Понял? Как бы ты протестировал асинхронный код?"
        XCTAssertEqual(detector.detect(in: segment(text))?.question, text)
    }

    // MARK: - Спекулятивная детекция на партиалах (A6)

    func testSpeculativeFiresOnPartialQuestionMark() {
        let q = detector.detectSpeculative(in: segment("как вы тестируете код?", isFinal: false))
        XCTAssertEqual(q?.question, "как вы тестируете код?")
    }

    func testSpeculativeIgnoresFinalSegment() {
        // detectSpeculative — только для партиалов; финал обрабатывает detect().
        XCTAssertNil(detector.detectSpeculative(in: segment("как вы тестируете код?", isFinal: true)))
    }

    func testSpeculativeIgnoresGrowingPartialWithoutQuestionMark() {
        // Растущая полуфраза без «?» не должна триггерить (иначе перезапуск на каждом слове).
        XCTAssertNil(detector.detectSpeculative(in: segment("как вы тестируете", isFinal: false)))
    }

    func testSpeculativeIgnoresTooShortQuestion() {
        // «да?» — слишком короткий для спекуляции (minWords=3 по умолчанию).
        XCTAssertNil(detector.detectSpeculative(in: segment("да?", isFinal: false)))
    }

    func testSpeculativePassesFullContext() {
        let text = "это понятно. а как вы мокаете сеть?"
        let q = detector.detectSpeculative(in: segment(text, isFinal: false))
        XCTAssertEqual(q?.question, text, "спекуляция тоже отдаёт весь контекст партиала")
    }
}
