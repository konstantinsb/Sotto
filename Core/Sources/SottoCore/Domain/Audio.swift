import Foundation

/// Источник аудио. От источника зависит, кого мы слушаем: себя или собеседника.
public enum AudioSource: String, Sendable, Codable, Hashable {
    case microphone   // собственный голос (AVAudioEngine)
    case system       // системный звук / собеседник (ScreenCaptureKit / Core Audio taps)
}

/// Небольшой фрагмент аудио (PCM-сэмплы) с разметкой источника.
/// В реальном конвейере сюда попадают сэмплы 16 кГц моно после ресемплинга.
public struct AudioChunk: Sendable {
    public let source: AudioSource
    public let sampleRate: Int
    public let samples: [Float]
    /// Время от старта сессии, секунды.
    public let timestamp: TimeInterval

    public init(source: AudioSource, sampleRate: Int, samples: [Float], timestamp: TimeInterval) {
        self.source = source
        self.sampleRate = sampleRate
        self.samples = samples
        self.timestamp = timestamp
    }
}
