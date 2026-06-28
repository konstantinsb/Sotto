import XCTest
@testable import SottoCore

// MARK: - A3: GenerationOptions

final class GenerationOptionsTests: XCTestCase {
    func testLiveHintIsBounded() {
        XCTAssertEqual(GenerationOptions.liveHint.maxTokens, 350)
        XCTAssertEqual(GenerationOptions.liveHint.temperature, 0.4)
    }

    func testUnboundedHasNoLimit() {
        XCTAssertNil(GenerationOptions.unbounded.maxTokens)
    }

    func testForModeMapping() {
        XCTAssertEqual(GenerationOptions.forMode(.iosInterview), .liveHint)
        XCTAssertEqual(GenerationOptions.forMode(.englishCoach).temperature, 0.5)
        XCTAssertEqual(GenerationOptions.forMode(.meetingSummarizer).maxTokens, 320)
    }

    func testInitClampsInvalidValues() {
        XCTAssertEqual(GenerationOptions(maxTokens: 0).maxTokens, 1)        // ≥1
        XCTAssertEqual(GenerationOptions(temperature: -3).temperature, 0)   // ≥0
    }
}

// MARK: - SessionConfiguration defaults

final class SessionConfigurationDefaultsTests: XCTestCase {
    func testDefaultsAreLatencyOriented() {
        let cfg = SessionConfiguration(mode: .iosInterview, systemPrompt: "s")
        XCTAssertEqual(cfg.generationOptions, .liveHint)
        XCTAssertTrue(cfg.useContextRetrieval)
        XCTAssertTrue(cfg.speculateOnPartials)
    }

    func testGenerationOptionsFollowMode() {
        let cfg = SessionConfiguration(mode: .englishCoach, systemPrompt: "s")
        XCTAssertEqual(cfg.generationOptions, GenerationOptions.forMode(.englishCoach))
    }
}

// MARK: - A4: рекомендация модели по устройству

final class ModelRecommendationTests: XCTestCase {
    private func device(ramGB: Int) -> DeviceCapabilities {
        DeviceCapabilities(chipName: "Test", totalRAMBytes: UInt64(ramGB) * 1_073_741_824, performanceCores: 8)
    }

    func testWeakDeviceGetsSmallestLLM() {
        let id = ModelRegistry.default.recommendedLLMID(for: device(ramGB: 8))
        XCTAssertEqual(id, "llama3.2-3b-4bit", "на 8 ГБ — самая маленькая/быстрая модель")
    }

    func testBalancedDeviceGetsDefaultLLM() {
        let id = ModelRegistry.default.recommendedLLMID(for: device(ramGB: 16))
        XCTAssertEqual(id, "qwen3-4b-4bit")
    }

    func testHighRAMDoesNotAutoPick8B() {
        // 8B медленнее — автоматически не выбираем даже при изобилии памяти.
        let id = ModelRegistry.default.recommendedLLMID(for: device(ramGB: 64))
        XCTAssertEqual(id, "qwen3-4b-4bit")
    }

    func testRecommendedSelectionUsesParakeetAndDeviceLLM() {
        let sel = ModelSelection.recommended(for: device(ramGB: 8), registry: .default)
        XCTAssertEqual(sel.asrModelID, "parakeet-tdt-v3")
        XCTAssertEqual(sel.llmModelID, "llama3.2-3b-4bit")
    }
}

// MARK: - A10: компактизация OCR-текста

final class CodeAssistPromptBuilderTests: XCTestCase {
    func testCompactDropsNoiseAndCollapsesSpaces() {
        let raw = "line  one\n\n\n   \n*\nline\t\ttwo\n"
        XCTAssertEqual(CodeAssistPromptBuilder.compact(raw), "line one\nline two")
    }

    func testBuildCapsLengthAndWrapsScreen() {
        let builder = CodeAssistPromptBuilder(maxScreenChars: 500)
        let prompt = builder.build(screenText: String(repeating: "x", count: 5000))
        XCTAssertTrue(prompt.user.contains("=== Экран (OCR) ==="))
        XCTAssertLessThanOrEqual(prompt.user.count, 600)   // 500 экрана + обёртка
    }

    func testDefaultCapIsReduced() {
        XCTAssertEqual(CodeAssistPromptBuilder().maxScreenChars, 4000)
    }
}

// MARK: - A5b: LRU-кэш эмбеддинга запроса

final class ContextEngineCacheTests: XCTestCase {
    func testRepeatedQueryHitsCache() async {
        let embedder = CountingEmbedder(vocabulary: ["актор", "concurrency", "core", "ml"])
        let profile = UserProfile(about: "Я работал с акторами и concurrency.",
                                  projects: "Core ML проект.", stack: "", starStories: "")
        let engine = ContextEngine(profile: profile, embedder: embedder)
        await engine.warmUp()

        let afterWarmUp = await embedder.embedCalls
        _ = await engine.topK(for: "акторы и concurrency", k: 1)
        _ = await engine.topK(for: "акторы и concurrency", k: 1)   // повтор → кэш
        let afterQueries = await embedder.embedCalls

        XCTAssertEqual(afterQueries - afterWarmUp, 1, "повторный запрос не пересчитывает эмбеддинг")
    }

    func testDifferentQueriesEachEmbedOnce() async {
        let embedder = CountingEmbedder(vocabulary: ["актор", "core", "ml"])
        let profile = UserProfile(about: "акторы", projects: "core ml", stack: "", starStories: "")
        let engine = ContextEngine(profile: profile, embedder: embedder)
        await engine.warmUp()

        let before = await embedder.embedCalls
        _ = await engine.topK(for: "актор", k: 1)
        _ = await engine.topK(for: "core ml", k: 1)
        let after = await embedder.embedCalls
        XCTAssertEqual(after - before, 2)
    }
}

// MARK: - Сверка вопросов (спекуляция ↔ финал)

final class QuestionMatchingTests: XCTestCase {
    func testNormalizeStripsPunctuationAndCase() {
        XCTAssertEqual(SessionActor.normalize("Как ВЫ — тестируете? код!"), "как вы тестируете код")
    }

    func testCloseEnoughMatchesPrefixOverThreshold() {
        XCTAssertTrue(SessionActor.closeEnough("как вы тестируете", "как вы тестируете код"))
        XCTAssertTrue(SessionActor.closeEnough("как вы тестируете код", "как вы тестируете код"))
    }

    func testCloseEnoughRejectsShortCommonPrefix() {
        XCTAssertFalse(SessionActor.closeEnough("как", "как вы тестируете код данных"))
    }
}

// MARK: - Вырезание <think>…</think>

final class ThinkTagStripperTests: XCTestCase {
    private func strip(_ chunks: [String]) -> String {
        var stripper = ThinkTagStripper()
        var out = ""
        for chunk in chunks { out += stripper.feed(chunk) }
        out += stripper.finish()
        return out
    }

    func testStripsEmptyThinkBlock() {
        // Главный кейс: Qwen3 с /no_think шлёт пустой <think></think> в начале.
        XCTAssertEqual(strip(["<think>\n\n</think>\n\nОтвет по делу"]), "Ответ по делу")
    }

    func testStripsThinkBlockSplitAcrossChunks() {
        XCTAssertEqual(strip(["<th", "ink>", "\n\n", "</thi", "nk>", "Ответ"]), "Ответ")
    }

    func testStripsThinkWithContent() {
        XCTAssertEqual(strip(["<think>рассуждаю</think>финал"]), "финал")
    }

    func testPassesThroughPlainText() {
        XCTAssertEqual(strip(["Просто ", "ответ"]), "Просто ответ")
    }

    func testKeepsNonThinkAngleBrackets() {
        XCTAssertEqual(strip(["<p>код</p>"]), "<p>код</p>")
    }
}

// MARK: - Helpers

/// Эмбеддер со счётчиком вызовов (для проверки кэша запросов).
private actor CountingEmbedder: TextEmbedder {
    let vocabulary: [String]
    private(set) var embedCalls = 0
    init(vocabulary: [String]) { self.vocabulary = vocabulary }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCalls += 1
        return texts.map { text in
            let lower = text.lowercased()
            return vocabulary.map { lower.contains($0) ? Float(1) : Float(0) }
        }
    }
}
