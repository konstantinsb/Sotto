import XCTest
@testable import SottoCore

final class VectorStoreTests: XCTestCase {
    func testTopKByCosine() {
        var store = VectorStore()
        let a = TextChunk(text: "A", sourceTitle: "s")
        let b = TextChunk(text: "B", sourceTitle: "s")
        let c = TextChunk(text: "C", sourceTitle: "s")
        store.replaceAll(chunks: [a, b, c], vectors: [[1, 0], [0, 1], [0.7, 0.7]])

        let top = store.topK(query: [2, 0], k: 2)   // нормализуется к [1,0]
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].chunk.text, "A")       // ближе всего
        XCTAssertEqual(top[1].chunk.text, "C")       // затем диагональ
        XCTAssertGreaterThan(top[0].score, top[1].score)
    }

    func testEmptyStore() {
        let store = VectorStore()
        XCTAssertTrue(store.topK(query: [1, 0], k: 3).isEmpty)
        XCTAssertEqual(store.count, 0)
    }
}

final class TextChunkerTests: XCTestCase {
    func testShortParagraphsOneChunkEach() {
        let chunks = TextChunker(maxCharsPerChunk: 400)
            .chunks(from: "Первый абзац.\nВторой абзац.", sourceTitle: "Опыт")
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].sourceTitle, "Опыт")
    }

    func testLongParagraphSplitBySentences() {
        let long = String(repeating: "Это предложение про Swift. ", count: 10)
        let chunks = TextChunker(maxCharsPerChunk: 80).chunks(from: long, sourceTitle: "s")
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 120 })
    }

    func testEmptyText() {
        XCTAssertTrue(TextChunker().chunks(from: "   \n  ", sourceTitle: "s").isEmpty)
    }
}

final class UserProfileTests: XCTestCase {
    func testSummaryJoinsNonEmptySections() {
        let profile = UserProfile(about: "5 лет iOS", projects: "", stack: "Swift", starStories: "")
        XCTAssertTrue(profile.summary.contains("Опыт: 5 лет iOS"))
        XCTAssertTrue(profile.summary.contains("Стек: Swift"))
        XCTAssertFalse(profile.summary.contains("Проекты"))
        XCTAssertFalse(profile.isEmpty)
    }

    func testEmptyProfile() {
        XCTAssertTrue(UserProfile().isEmpty)
    }

    func testPromptSummaryIncludesAllSections() {
        // Раньше до постоянного контекста доезжал только about — проверяем, что теперь
        // в сводку входят все непустые секции (проекты/стек/STAR не теряются).
        let profile = UserProfile(
            about: "5 лет iOS",
            projects: "офлайн-ASR",
            stack: "Swift, SwiftUI",
            starStories: "починил гонку данных"
        )
        let summary = profile.promptSummary()
        XCTAssertTrue(summary.contains("Опыт: 5 лет iOS"))
        XCTAssertTrue(summary.contains("Проекты: офлайн-ASR"))
        XCTAssertTrue(summary.contains("Стек: Swift, SwiftUI"))
        XCTAssertTrue(summary.contains("STAR-истории: починил гонку данных"))
    }

    func testPromptSummaryCapsLength() {
        let profile = UserProfile(about: String(repeating: "x", count: 5000))
        XCTAssertEqual(profile.promptSummary(maxChars: 100).count, 100)
    }

    func testCodableRoundTrip() throws {
        let profile = UserProfile(about: "a", projects: "b", stack: "c", starStories: "d")
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(UserProfile.self, from: data), profile)
    }
}

final class ContextEngineTests: XCTestCase {
    /// RAG end-to-end на детерминированном bag-of-words эмбеддере.
    func testRetrievesRelevantChunk() async {
        let profile = UserProfile(
            about: "Я работал с акторами и concurrency в Swift.",
            projects: "Делал офлайн-распознавание речи на Core ML.",
            stack: "",
            starStories: ""
        )
        let vocabulary = ["актор", "concurrency", "core ml", "распознавание", "речи", "swift"]
        let engine = ContextEngine(profile: profile, embedder: BagOfWordsEmbedder(vocabulary: vocabulary))
        await engine.warmUp()

        let results = await engine.topK(for: "расскажи про акторов и concurrency", k: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first!.text.lowercased().contains("актор"))
    }

    func testEmptyProfileReturnsNothing() async {
        let engine = ContextEngine(profile: UserProfile(), embedder: BagOfWordsEmbedder(vocabulary: ["x"]))
        await engine.warmUp()
        let results = await engine.topK(for: "любой запрос", k: 3)
        XCTAssertTrue(results.isEmpty)
    }

    func testRetrievesFromQACorpus() async {
        // Профиль пустой — релевантное приходит из базы Q&A (доп. источник RAG).
        let corpus = QACorpus(entries: [
            QAEntry(topic: "ARC", question: "Что такое ARC?", answer: "Автоматический подсчёт ссылок."),
            QAEntry(topic: "COW", question: "Что такое copy-on-write?", answer: "Копирование буфера при мутации.")
        ])
        let vocabulary = ["arc", "ссылок", "copy", "буфер", "мутации"]
        let engine = ContextEngine(
            profile: UserProfile(),
            corpus: corpus,
            embedder: BagOfWordsEmbedder(vocabulary: vocabulary)
        )
        await engine.warmUp()

        let results = await engine.topK(for: "расскажи про copy-on-write и буфер", k: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first!.text.lowercased().contains("буфер"))
    }
}

/// Детерминированный эмбеддер для тестов: вектор = наличие слов словаря в тексте.
private struct BagOfWordsEmbedder: TextEmbedder {
    let vocabulary: [String]
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let lower = text.lowercased()
            return vocabulary.map { lower.contains($0) ? Float(1) : Float(0) }
        }
    }
}
