import XCTest
@testable import SottoCore

final class AudioBackpressureTests: XCTestCase {

    // MARK: - Детект разрыва (drop-to-live выбросил аудио)

    func testContiguousChunksAreNotDiscontinuity() {
        // Соседние 0.1-с чанки: старт следующего ровно через длительность предыдущего.
        XCTAssertFalse(AudioBackpressure.isDiscontinuity(
            previousStart: 1.0, previousDuration: 0.1, nextStart: 1.1))
    }

    func testSingleDroppedChunkWithinTolerance() {
        // Потеря одного 0.1-с чанка (старт прыгнул на 0.1 сверх ожидаемого) — в пределах
        // допуска, окно не сбрасываем (склейка незаметна).
        XCTAssertFalse(AudioBackpressure.isDiscontinuity(
            previousStart: 1.0, previousDuration: 0.1, nextStart: 1.2))
    }

    func testLargeGapIsDiscontinuity() {
        // Несколько секунд выброшено — явный разрыв.
        XCTAssertTrue(AudioBackpressure.isDiscontinuity(
            previousStart: 1.0, previousDuration: 0.1, nextStart: 5.0))
    }

    func testGapJustOverToleranceIsDiscontinuity() {
        // Ожидаемый старт 1.1; фактический 1.31 → разрыв 0.21 > допуска 0.15.
        XCTAssertTrue(AudioBackpressure.isDiscontinuity(
            previousStart: 1.0, previousDuration: 0.1, nextStart: 1.31))
    }

    func testCustomTolerance() {
        XCTAssertFalse(AudioBackpressure.isDiscontinuity(
            previousStart: 0, previousDuration: 0.1, nextStart: 0.5, tolerance: 1.0))
        XCTAssertTrue(AudioBackpressure.isDiscontinuity(
            previousStart: 0, previousDuration: 0.1, nextStart: 0.5, tolerance: 0.2))
    }

    // MARK: - dropToLive

    private func chunk(at timestamp: TimeInterval) -> AudioChunk {
        AudioChunk(source: .system, sampleRate: 16_000, samples: [0, 0], timestamp: timestamp)
    }

    func testDropToLivePassesThroughWhenUnderLimit() async {
        // Меньше лимита — ничего не теряется, порядок сохранён.
        let source = AsyncStream<AudioChunk> { c in
            for i in 0..<5 { c.yield(chunk(at: Double(i) * 0.1)) }
            c.finish()
        }
        var received: [TimeInterval] = []
        for await c in AudioBackpressure.dropToLive(source, maxChunks: 40) {
            received.append(c.timestamp)
        }
        let expected = (0..<5).map { Double($0) * 0.1 }
        XCTAssertEqual(received.count, expected.count)
        for (got, want) in zip(received, expected) {
            XCTAssertEqual(got, want, accuracy: 0.0001)
        }
    }

    /// Документирует механизм, на который опирается drop-to-live: `.bufferingNewest`
    /// при переполнении держит самые свежие элементы, выбрасывая старые.
    func testBufferingNewestKeepsLatest() async {
        let stream = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(2)) { c in
            c.yield(1); c.yield(2); c.yield(3); c.yield(4)
            c.finish()
        }
        var got: [Int] = []
        for await v in stream { got.append(v) }
        XCTAssertEqual(got, [3, 4])
    }
}
