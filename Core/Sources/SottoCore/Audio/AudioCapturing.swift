import Foundation

/// Источник аудио, отдающий поток фрагментов.
///
/// Реализации (в следующих фазах): `MicrophoneCapture` (AVAudioEngine),
/// `SystemAudioCapture` (Core Audio taps / ScreenCaptureKit). В фазе 1 — фейк.
/// Остановка управляется через отмену задачи-потребителя и завершение потока.
public protocol AudioCapturing: Sendable {
    func stream() -> AsyncStream<AudioChunk>
}
