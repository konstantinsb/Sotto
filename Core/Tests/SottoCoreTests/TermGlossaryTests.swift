import XCTest
@testable import SottoCore

final class TermGlossaryTests: XCTestCase {

    func testCorrectsKnownGarbledTerms() {
        let g = TermGlossary.iosDefault
        XCTAssertEqual(g.correct("Расскажи про асинка вайт"), "Расскажи про async/await")
        XCTAssertEqual(g.correct("что такое ретайн цикл"), "что такое retain cycle")
        XCTAssertEqual(g.correct("модель на кордета"), "модель на Core Data")
    }

    func testCorrectionIsCaseInsensitive() {
        let g = TermGlossary.iosDefault
        XCTAssertEqual(g.correct("АСИНКА ВАЙТ"), "async/await")
    }

    func testLeavesUnknownTextUntouched() {
        let g = TermGlossary.iosDefault
        let input = "Расскажи про дженерики и протоколы"
        XCTAssertEqual(g.correct(input), input)
    }

    func testLongerKeysWinOverShorterPrefixes() {
        // «коплишн кложери» (длиннее) должно сработать раньше «коплишн кложер»,
        // иначе остался бы хвост «и».
        let g = TermGlossary.iosDefault
        XCTAssertEqual(g.correct("коплишн кложери"), "completion closure")
    }

    func testPromptBlockListsCanonicalTerms() {
        let block = TermGlossary.iosDefault.promptBlock()
        XCTAssertTrue(block.contains("async/await"))
        XCTAssertTrue(block.contains("ARC"))
    }

    func testPromptBlockRespectsMaxTerms() {
        let g = TermGlossary(
            canonicalTerms: ["a", "b", "c", "d"],
            corrections: []
        )
        let block = g.promptBlock(maxTerms: 2)
        XCTAssertTrue(block.contains("a, b"))
        XCTAssertFalse(block.contains("c"))
    }

    func testEmptyGlossaryProducesEmptyBlock() {
        let g = TermGlossary(canonicalTerms: [], corrections: [])
        XCTAssertTrue(g.isEmpty)
        XCTAssertEqual(g.promptBlock(), "")
        XCTAssertEqual(g.correct("любой текст"), "любой текст")
    }

    func testForModeAttachesGlossaryOnlyToTechnicalInterviews() {
        XCTAssertNotNil(TermGlossary.forMode(.iosInterview))
        XCTAssertNotNil(TermGlossary.forMode(.systemDesignInterview))
        XCTAssertNil(TermGlossary.forMode(.salesCall))
        XCTAssertNil(TermGlossary.forMode(.englishCoach))
    }
}
