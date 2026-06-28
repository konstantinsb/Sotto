import XCTest
@testable import SottoCore

final class QACorpusTests: XCTestCase {

    func testDefaultCorpusIsNonEmptyAndWellFormed() {
        let corpus = QACorpus.iosDefault
        XCTAssertFalse(corpus.isEmpty)
        for entry in corpus.entries {
            XCTAssertFalse(entry.topic.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(entry.question.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(entry.answer.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testSourcesMapOnePerEntryWithPrefixedTitle() {
        let corpus = QACorpus(entries: [
            QAEntry(topic: "ARC", question: "Что такое ARC?", answer: "Подсчёт ссылок.")
        ])
        let sources = corpus.sources
        XCTAssertEqual(sources.count, corpus.entries.count)
        XCTAssertEqual(sources.first?.title, "Q&A: ARC")
        XCTAssertTrue(sources.first?.text.contains("Что такое ARC?") ?? false)
        XCTAssertTrue(sources.first?.text.contains("Подсчёт ссылок.") ?? false)
    }

    func testForModeAttachesCorpusOnlyToRelevantModes() {
        XCTAssertFalse(QACorpus.forMode(.iosInterview).isEmpty)
        XCTAssertFalse(QACorpus.forMode(.systemDesignInterview).isEmpty)
        XCTAssertTrue(QACorpus.forMode(.salesCall).isEmpty)
        XCTAssertTrue(QACorpus.forMode(.englishCoach).isEmpty)
    }

    func testCodableRoundTrip() throws {
        let corpus = QACorpus(entries: [QAEntry(topic: "t", question: "q", answer: "a")])
        let data = try JSONEncoder().encode(corpus)
        XCTAssertEqual(try JSONDecoder().decode(QACorpus.self, from: data), corpus)
    }
}
