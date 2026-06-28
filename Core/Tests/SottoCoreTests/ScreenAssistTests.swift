import XCTest
@testable import SottoCore

final class ScreenAssistTests: XCTestCase {

    private func collect(_ stream: AsyncStream<ScreenAssistEvent>) async -> [ScreenAssistEvent] {
        var events: [ScreenAssistEvent] = []
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        for await event in stream {
            events.append(event)
            if ContinuousClock().now > deadline { break }
        }
        return events
    }

    func testSolveProducesRecognizedTextAndSolution() async {
        let actor = ScreenAssistActor(
            source: FakeScreenTextSource(text: "Задача: реверс связного списка"),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1), answer: "Идём по списку, переворачивая ссылки. O(n)/O(1)."),
            promptBuilder: CodeAssistPromptBuilder()
        )
        let events = await collect(actor.solve())

        var recognized: String?
        var solution: String?
        var phases: [ScreenAssistPhase] = []
        for event in events {
            switch event {
            case .recognizedText(let text): recognized = text
            case .solutionCompleted(let full): solution = full
            case .stateChanged(let phase): phases.append(phase)
            default: break
            }
        }
        XCTAssertEqual(recognized, "Задача: реверс связного списка")
        XCTAssertFalse(solution?.isEmpty ?? true, "решение должно быть непустым")
        XCTAssertEqual(phases.last, .done)
    }

    func testScreenReadFailureEmitsFailure() async {
        let actor = ScreenAssistActor(
            source: ThrowingScreenTextSource(),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1))
        )
        let events = await collect(actor.solve())

        var failure: String?
        var sawFailed = false
        for event in events {
            if case .failure(let message) = event { failure = message }
            if case .stateChanged(.failed) = event { sawFailed = true }
        }
        XCTAssertTrue(sawFailed)
        XCTAssertTrue(failure?.contains("нет экрана") ?? false, "сообщение должно включать причину")
    }

    func testEmptyScreenEmitsFailure() async {
        let actor = ScreenAssistActor(
            source: FakeScreenTextSource(text: "   "),
            llm: FakeLLMEngine(perTokenDelay: .milliseconds(1), warmUpDelay: .milliseconds(1))
        )
        let events = await collect(actor.solve())
        let sawFailed = events.contains { if case .stateChanged(.failed) = $0 { return true } else { return false } }
        XCTAssertTrue(sawFailed, "пустой экран — это сбой, а не пустое решение")
    }

    // MARK: - PromptBuilder

    func testPromptBuilderIncludesScreenAndProfile() {
        let prompt = CodeAssistPromptBuilder().build(screenText: "two sum", profileSummary: "iOS 5 лет")
        XCTAssertTrue(prompt.user.contains("two sum"))
        XCTAssertTrue(prompt.user.contains("iOS 5 лет"))
        XCTAssertFalse(prompt.system.isEmpty)
    }

    func testPromptBuilderPlacesSpokenQuestionBeforeScreen() {
        let prompt = CodeAssistPromptBuilder().build(
            screenText: "two sum",
            spokenQuestion: "Что выведется в консоль?"
        )
        guard let questionRange = prompt.user.range(of: "Вопрос интервьюера вслух"),
              let screenRange = prompt.user.range(of: "=== Экран (OCR) ===") else {
            return XCTFail("оба блока должны присутствовать в user-промпте")
        }
        XCTAssertTrue(prompt.user.contains("Что выведется в консоль?"))
        XCTAssertLessThan(questionRange.lowerBound, screenRange.lowerBound,
                          "вопрос интервьюера должен идти ПЕРЕД блоком экрана")
    }

    func testPromptBuilderOmitsSpokenQuestionWhenEmpty() {
        let prompt = CodeAssistPromptBuilder().build(screenText: "two sum", spokenQuestion: "   ")
        XCTAssertFalse(prompt.user.contains("Вопрос интервьюера вслух"),
                       "пустой вопрос не должен порождать блок")
    }

    func testPromptBuilderCapsScreenLength() {
        let long = String(repeating: "a", count: 10_000)
        let prompt = CodeAssistPromptBuilder(maxScreenChars: 1000).build(screenText: long)
        XCTAssertLessThan(prompt.user.count, 1200, "экран должен быть обрезан до лимита")
    }

    func testPromptGuidesOutputPredictionAndNonDeterminism() {
        let prompt = CodeAssistPromptBuilder().build(screenText: "что выведется?")
        // Системный промпт должен вести к предсказанию вывода и запрещать выдумывать адреса/треды.
        XCTAssertTrue(prompt.system.contains("ВЫВЕДЕТСЯ В КОНСОЛЬ"))
        XCTAssertTrue(prompt.system.contains("0x"))           // упоминание адресов памяти
        XCTAssertTrue(prompt.system.lowercased().contains("тред"))
    }

    func testCompactPreservesCodeBraces() {
        // Фигурные/круглые скобки на отдельных строках — структура кода, не мусор.
        let code = "func f() {\n}\n.\n  let x = 1  "
        let compacted = CodeAssistPromptBuilder.compact(code)
        let lines = compacted.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("}"), "закрывающая скобка не должна выбрасываться")
        XCTAssertTrue(lines.contains("let x = 1"), "внутренние пробелы схлопнуты, края обрезаны")
        XCTAssertFalse(lines.contains("."), "одиночная точка — OCR-шум, выбрасывается")
    }

    // MARK: - State reducer

    func testStateReducerAccumulatesTokensAndResetsOnCapture() {
        var state = ScreenAssistState()
        state.apply(.stateChanged(.capturing))
        state.apply(.recognizedText("задача"))
        state.apply(.solutionStarted)
        state.apply(.solutionToken("реш"))
        state.apply(.solutionToken("ение"))
        XCTAssertEqual(state.solution, "решение")
        XCTAssertEqual(state.recognizedText, "задача")
        XCTAssertTrue(state.isRunning)

        // Новый разбор сбрасывает прошлый результат.
        state.apply(.stateChanged(.capturing))
        XCTAssertEqual(state.solution, "")
        XCTAssertEqual(state.recognizedText, "")
        XCTAssertNil(state.lastError)
    }
}

private struct ThrowingScreenTextSource: ScreenTextSource {
    struct ReadError: LocalizedError { var errorDescription: String? { "нет экрана" } }
    func recognizeScreenText(region: CaptureRegion?) async throws -> RecognizedScreen { throw ReadError() }
}
