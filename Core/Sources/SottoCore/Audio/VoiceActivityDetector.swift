import Foundation

/// Результат детекции речи на одном кадре.
public struct VADResult: Sendable, Equatable {
    public let isSpeech: Bool
    public let rms: Float

    public init(isSpeech: Bool, rms: Float) {
        self.isSpeech = isSpeech
        self.rms = rms
    }
}

/// Детектор речевой активности. За протоколом — чтобы заменить энергетический VAD
/// на модельный (например, Silero) без правок конвейера.
public protocol VoiceActivityDetecting: Sendable {
    func process(_ samples: [Float]) -> VADResult
}

/// Энергетический VAD: речь = RMS выше порога. После спада громкости держит статус
/// «речь» ещё `hangoverFrames` кадров (hangover), чтобы не рвать фразу на паузах.
public final class EnergyVAD: VoiceActivityDetecting, @unchecked Sendable {
    private let threshold: Float
    private let hangoverFrames: Int
    private var silenceRun = 0
    private var active = false
    private let lock = NSLock()

    public init(threshold: Float = 0.012, hangoverFrames: Int = 5) {
        self.threshold = threshold
        self.hangoverFrames = max(0, hangoverFrames)
    }

    public func process(_ samples: [Float]) -> VADResult {
        let level = Self.rms(samples)
        lock.lock(); defer { lock.unlock() }
        if level >= threshold {
            active = true
            silenceRun = 0
        } else if active {
            silenceRun += 1
            if silenceRun > hangoverFrames { active = false }
        }
        return VADResult(isSpeech: active, rms: level)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }
}
