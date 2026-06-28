import XCTest
@testable import SottoCore

final class TranscriptionEvalTests: XCTestCase {

    func testIdenticalIsPerfect() {
        let e = TranscriptionEvaluator.evaluate(
            referenceText: "Расскажите про дебаунс в Swift",
            liveText: "расскажите, про дебаунс в swift!"
        )
        XCTAssertEqual(e.wordErrors, 0, "пунктуация и регистр не считаются ошибками")
        XCTAssertEqual(e.wordErrorRate, 0)
        XCTAssertEqual(e.accuracyPercent, 100)
    }

    func testWordErrorsCounted() {
        // эталон 4 слова, одна замена → WER 25%
        let e = TranscriptionEvaluator.evaluate(
            referenceText: "как вы решаете гонки",
            liveText: "как вы решали гонки"
        )
        XCTAssertEqual(e.referenceWordCount, 4)
        XCTAssertEqual(e.wordErrors, 1)
        XCTAssertEqual(e.wordErrorRate, 0.25, accuracy: 0.001)
        XCTAssertEqual(e.accuracyPercent, 75)
    }

    func testEmptyLiveIsFullError() {
        let e = TranscriptionEvaluator.evaluate(referenceText: "одно два три", liveText: "")
        XCTAssertEqual(e.wordErrorRate, 1)
        XCTAssertEqual(e.accuracyPercent, 0)
    }

    func testReportContainsBothTexts() {
        let e = TranscriptionEvaluator.evaluate(referenceText: "эталон текст", liveText: "живой текст")
        let report = TranscriptionEvaluator.report(e)
        XCTAssertTrue(report.contains("эталон текст"))
        XCTAssertTrue(report.contains("живой текст"))
        XCTAssertTrue(report.contains("WER"))
        XCTAssertTrue(report.contains("Термины"))
    }

    // MARK: - Терм-метрика (§8: WER врёт, важна выживаемость терминов)

    func testContainsTermRespectsWordBoundaries() {
        XCTAssertTrue(TranscriptionEvaluator.containsTerm("что такое arc вообще", "arc"))
        XCTAssertFalse(TranscriptionEvaluator.containsTerm("поиск search здесь", "arc"))  // не часть слова
        XCTAssertTrue(TranscriptionEvaluator.containsTerm("про async/await кратко", "async/await"))
    }

    func testTermSurvivalNormalizesGarbledAndCountsSurvivors() {
        // Эталон коверкает термины («асинка вайт», «кордета») — глоссарий чинит их до канона;
        // живая теряет Core Data, но сохраняет async/await и SwiftUI.
        let e = TranscriptionEvaluator.evaluate(
            referenceText: "расскажи про асинка вайт и кордета и swiftui",
            liveText: "асинка вайт и swiftui"
        )
        XCTAssertEqual(e.terms.termsInReference, 3)          // async/await, Core Data, SwiftUI
        XCTAssertEqual(e.terms.survivedInLive, 2)            // async/await, SwiftUI
        XCTAssertEqual(e.terms.missingTerms, ["Core Data"])
        XCTAssertEqual(e.terms.survivalPercent, 67)
    }

    func testTermSurvivalIsVacuouslyFullWhenNoTerms() {
        let e = TranscriptionEvaluator.evaluate(referenceText: "привет как дела", liveText: "")
        XCTAssertEqual(e.terms.termsInReference, 0)
        XCTAssertEqual(e.terms.survivalPercent, 100)         // нечего терять
    }

    func testWavRoundTrip() throws {
        // Запишем WAV нашим writer'ом и прочитаем обратно — сэмплы близки.
        let tmp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try XCTUnwrap(WavFileWriter(url: tmp, sampleRate: 16_000))
        let input: [Float] = [0, 0.5, -0.5, 1.0, -1.0, 0.25]
        writer.append(input)
        writer.close()

        let read = try XCTUnwrap(TranscriptionEvaluator.readWavSamples(tmp))
        XCTAssertEqual(read.count, input.count)
        for (a, b) in zip(input, read) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }
}
