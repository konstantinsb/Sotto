import XCTest
@testable import SottoCore

final class CodeAssistTaskKindTests: XCTestCase {

    // MARK: - inferTaskKind

    func testSpokenOutputQuestionInfersOutput() {
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "let x = 1", spokenQuestion: "Что выведется?")
        XCTAssertEqual(kind, .output)
    }

    func testSpokenRefactorQuestionInfersRefactor() {
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "func f() {}", spokenQuestion: "Отрефактори этот код")
        XCTAssertEqual(kind, .refactor)
    }

    func testSpokenComplexityQuestionInfersAlgorithm() {
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "массив", spokenQuestion: "Оцени сложность")
        XCTAssertEqual(kind, .algorithm)
    }

    func testSpokenWriteAlgorithmQuestionInfersAlgorithm() {
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "массив", spokenQuestion: "Напиши алгоритм")
        XCTAssertEqual(kind, .algorithm)
    }

    func testSpokenFindBugQuestionInfersSolve() {
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "let x = 1", spokenQuestion: "Найди баг")
        XCTAssertEqual(kind, .solve)
    }

    func testEmptyQuestionAndNeutralScreenDefaultsToSolve() {
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "struct Foo { var bar: Int }", spokenQuestion: "")
        XCTAssertEqual(kind, .solve, "без сигналов — дефолт .solve")
    }

    func testSpokenQuestionTakesPriorityOverScreen() {
        // Экран намекает на «реши», но вслух спросили про вывод — побеждает вопрос.
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "реши задачу: реверс списка", spokenQuestion: "Что выведется в консоль?")
        XCTAssertEqual(kind, .output)
    }

    func testFixBugInAlgorithmInfersSolve() {
        // Баг-фикс важнее слова «алгоритм»: solve проверяется раньше algorithm.
        let kind = CodeAssistPromptBuilder.inferTaskKind(
            screenText: "func quickSort()", spokenQuestion: "Исправь баг в алгоритме")
        XCTAssertEqual(kind, .solve)
    }

    func testColloquialOutputFormsInferOutput() {
        // Разговорные формы вопроса про вывод (без «-ся», без «консоль») — тоже .output.
        XCTAssertEqual(
            CodeAssistPromptBuilder.inferTaskKind(screenText: "print(x)", spokenQuestion: "Что выведет код?"),
            .output)
        XCTAssertEqual(
            CodeAssistPromptBuilder.inferTaskKind(screenText: "let r = f()", spokenQuestion: "Что вернёт?"),
            .output)
    }

    // MARK: - build (инструкция под вид)

    func testBuildRefactorIncludesImprovementInstruction() {
        let prompt = CodeAssistPromptBuilder().build(
            screenText: "func f() {}", spokenQuestion: "Перепиши покрасивее")
        XCTAssertTrue(prompt.system.contains("УЛУЧШИТЬ"))
        XCTAssertTrue(prompt.system.contains("переписанный"))
    }

    func testBuildOutputIncludesLineByLineAndAddress() {
        let prompt = CodeAssistPromptBuilder().build(
            screenText: "print(x)", spokenQuestion: "Что выведется?")
        XCTAssertTrue(prompt.system.contains("ВЫВЕДЕТСЯ В КОНСОЛЬ"))
        XCTAssertTrue(prompt.system.contains("построчно"))
        XCTAssertTrue(prompt.system.contains("0x"))
        XCTAssertTrue(prompt.system.contains("не выдумывай"), "output-ветка несёт анти-галлюцинацию")
    }

    func testBuildSolveIncludesSolveInstruction() {
        let prompt = CodeAssistPromptBuilder().build(
            screenText: "let x = 1", spokenQuestion: "Найди баг")
        XCTAssertTrue(prompt.system.contains("РЕШИТЬ ЗАДАЧУ"))
    }

    func testBuildAlgorithmIncludesComplexity() {
        let prompt = CodeAssistPromptBuilder().build(
            screenText: "массив", spokenQuestion: "Оцени сложность")
        XCTAssertTrue(prompt.system.contains("АЛГОЗАДАЧА"))
        XCTAssertTrue(prompt.system.contains("O(...)"))
    }
}
