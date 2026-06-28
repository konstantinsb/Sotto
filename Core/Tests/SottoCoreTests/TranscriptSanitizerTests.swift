import XCTest
@testable import SottoCore

final class TranscriptSanitizerTests: XCTestCase {

    func testStripsSubtitleCreditsHallucination() {
        let text = "Редактор субтитров А.Семкин Корректор А.Егорова"
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations(text), "")
    }

    func testStripsRepeatedHallucinationButKeepsRealSpeech() {
        // Ровно случай из отчёта: реальная речь + 6 повторов титров + реальная речь.
        let credit = "Редактор субтитров А.Семкин Корректор А.Егорова."
        let text = "Как это можно оптимизировать? "
            + String(repeating: credit + " ", count: 6)
            + "Объекты какие есть, в чем их разница."
        let cleaned = TranscriptSanitizer.stripHallucinations(text)
        XCTAssertFalse(cleaned.lowercased().contains("субтитр"))
        XCTAssertTrue(cleaned.contains("оптимизировать"))
        XCTAssertTrue(cleaned.contains("Объекты"))
    }

    func testStripsThanksForWatching() {
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations("Спасибо за просмотр!"), "")
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations("Thanks for watching."), "")
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations("Продолжение следует..."), "")
    }

    func testKeepsNormalSpeechUntouched() {
        let text = "Как работает ARC и что делает для управления памятью?"
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations(text), text)
    }

    func testDoesNotFalsePositiveOnEditorWord() {
        // «редактор» сам по себе — живое слово, не должно резаться (маркер — «редактор субтитров»).
        let text = "Я открыл редактор и написал функцию."
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations(text), text)
    }

    func testEmptyInput() {
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations(""), "")
        XCTAssertEqual(TranscriptSanitizer.stripHallucinations("   "), "")
    }
}
