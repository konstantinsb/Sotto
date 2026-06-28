import Foundation

/// Движок расшифровки речи.
///
/// Принимает поток аудио-фрагментов, отдаёт поток событий: частичные гипотезы
/// (показываем сразу) и зафиксированные сегменты (при паузе). За этим протоколом
/// в фазе 3 встанет `WhisperKitEngine`; замена на whisper.cpp не затронет остальной код.
public protocol TranscriptionEngine: Sendable {
    /// Прогрев: загрузка модели и компиляция ядер. По умолчанию — ничего (для фейков).
    func warmUp() async throws
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent>
    /// Эталонная расшифровка целого аудио одним проходом (для авто-оценки качества
    /// после сессии). По умолчанию — пусто (фейки/движки без эталона).
    func transcribeWhole(_ samples: [Float]) async throws -> String
    /// Выгрузка модели и освобождение памяти. По умолчанию — ничего (для фейков).
    func unload() async
}

public extension TranscriptionEngine {
    func warmUp() async throws {}
    func transcribeWhole(_ samples: [Float]) async throws -> String { "" }
    func unload() async {}
}
