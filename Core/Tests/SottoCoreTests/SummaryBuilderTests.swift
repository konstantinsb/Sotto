import XCTest
@testable import SottoCore

final class SummaryBuilderTests: XCTestCase {
    private func seg(_ text: String, _ source: AudioSource) -> TranscriptSegment {
        TranscriptSegment(source: source, text: text, isFinal: true, start: 0, end: 1)
    }

    func testIncludesTranscriptAndRoles() {
        let prompt = SummaryBuilder().build(
            transcript: [seg("как дела с проектом?", .system), seg("почти готово", .microphone)],
            mode: .meetingSummarizer
        )
        XCTAssertTrue(prompt.user.contains("Собеседник: как дела с проектом?"))
        XCTAssertTrue(prompt.user.contains("Я: почти готово"))
        XCTAssertTrue(prompt.user.contains("Саммари встречи")) // mode.title
        XCTAssertFalse(prompt.system.isEmpty)
    }

    func testEmptyTranscript() {
        let prompt = SummaryBuilder().build(transcript: [], mode: .iosInterview)
        XCTAssertTrue(prompt.user.contains("(пусто)"))
    }

    func testKeepsTailWhenLong() {
        let builder = SummaryBuilder(maxTranscriptChars: 60)
        var segments: [TranscriptSegment] = []
        for i in 0..<50 { segments.append(seg("реплика номер \(i)", .system)) }
        let prompt = builder.build(transcript: segments, mode: .salesCall)
        XCTAssertTrue(prompt.user.contains("реплика номер 49"))   // хвост сохранён
        XCTAssertFalse(prompt.user.contains("реплика номер 0\n")) // начало обрезано
    }
}
