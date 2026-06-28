import XCTest
@testable import SottoCore

final class ModelManagerTests: XCTestCase {
    func testModelsDirectoryUnderApplicationSupport() {
        let dir = ModelManager.modelsDirectory
        XCTAssertTrue(dir.path.contains("Application Support/Sotto/Models"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path)) // создаётся при обращении
    }

    func testWhisperVariantFolderLayout() {
        let folder = ModelManager.whisperVariantFolder(variant: "openai_whisper-base")
        XCTAssertTrue(folder.path.hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-base"))
    }

    func testDownloadProgressPercentAndSize() {
        let p = DownloadProgress(fraction: 0.5, completedBytes: 1_000_000_000, totalBytes: 2_000_000_000)
        XCTAssertEqual(p.percent, 50)
        let size = try? XCTUnwrap(p.sizeText)
        XCTAssertTrue(size?.contains("/") ?? false, "размер — «скачано / всего»")

        // Без общего размера — текст размера отсутствует, доля клампится.
        let unknown = DownloadProgress(fraction: 1.7)
        XCTAssertNil(unknown.sizeText)
        XCTAssertEqual(unknown.fraction, 1.0)
    }

    func testFormatBytes() {
        XCTAssertTrue(ModelManager.formatBytes(0).contains("0"))
        XCTAssertTrue(ModelManager.formatBytes(2 * 1_000_000_000).localizedCaseInsensitiveContains("GB")
                      || ModelManager.formatBytes(2 * 1_000_000_000).contains("ГБ"))
        XCTAssertEqual(ModelManager.formatBytes(-5), ModelManager.formatBytes(0)) // clamp
    }

    func testDirectorySize() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data(repeating: 0, count: 4096)
        try data.write(to: tmp.appending(path: "a.bin"))
        try data.write(to: tmp.appending(path: "b.bin"))
        XCTAssertGreaterThan(ModelManager.directorySize(tmp), 0)
    }
}
