import XCTest
@testable import SottoCore

final class ModelRegistryTests: XCTestCase {
    private let registry = ModelRegistry.default

    func testDefaultSelectionExistsInRegistry() {
        XCTAssertNotNil(registry.info(id: ModelSelection.default.asrModelID))
        XCTAssertNotNil(registry.info(id: ModelSelection.default.llmModelID))
    }

    func testModelsFilteredByKind() {
        XCTAssertTrue(registry.models(of: .asr).allSatisfy { $0.kind == .asr })
        XCTAssertTrue(registry.models(of: .llm).allSatisfy { $0.kind == .llm })
        XCTAssertFalse(registry.models(of: .asr).isEmpty)
        XCTAssertFalse(registry.models(of: .llm).isEmpty)
    }

    func testInfoLookupReturnsRepo() {
        let llm = registry.info(id: "qwen3-4b-4bit")
        XCTAssertEqual(llm?.repo, "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(llm?.kind, .llm)
    }

    func testValidationFallsBackForUnknownIDs() {
        let broken = ModelSelection(asrModelID: "does-not-exist", llmModelID: "qwen3-8b-4bit")
        let fixed = broken.validated(against: registry)
        XCTAssertEqual(fixed.asrModelID, ModelSelection.default.asrModelID) // подставлен дефолт
        XCTAssertEqual(fixed.llmModelID, "qwen3-8b-4bit")                    // валидный сохранён
    }

    func testSelectionCodableRoundTrip() throws {
        let selection = ModelSelection(asrModelID: "whisper-small", llmModelID: "llama3.2-3b-4bit")
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(ModelSelection.self, from: data)
        XCTAssertEqual(selection, decoded)
    }

    func testAllDefaultIDsUnique() {
        let ids = (registry.asr + registry.llm).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "id моделей в реестре должны быть уникальны")
    }

    func testKindAwareLookupRejectsWrongKind() {
        XCTAssertNil(registry.info(id: "qwen3-4b-4bit", kind: .asr))     // это LLM, не ASR
        XCTAssertNotNil(registry.info(id: "qwen3-4b-4bit", kind: .llm))
        XCTAssertNil(registry.info(id: "whisper-small", kind: .llm))     // это ASR, не LLM
    }

    func testValidationRejectsKindMismatch() {
        // id перепутаны слотами (LLM в ASR-слоте и наоборот)
        let swapped = ModelSelection(asrModelID: "qwen3-4b-4bit", llmModelID: "whisper-small")
        let fixed = swapped.validated(against: registry)
        XCTAssertEqual(fixed.asrModelID, ModelSelection.default.asrModelID)
        XCTAssertEqual(fixed.llmModelID, ModelSelection.default.llmModelID)
    }
}
