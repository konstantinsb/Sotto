import AVFoundation

/// Реальный захват микрофона через `AVAudioEngine`.
///
/// Схема без блокировки real-time потока: tap пишет ресемплированные сэмплы в
/// `RingBuffer` и НЕ ждёт; отдельный consumer-таск читает буфер, нарезает на кадры
/// и отдаёт `AsyncStream<AudioChunk>`. При отставании consumer'а старые блоки
/// сбрасываются (backpressure) — это видно по `droppedBlocks`.
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {
    private let chunkDuration: TimeInterval
    private let ring = RingBuffer<[Float]>(capacity: 64)

    public init(chunkDuration: TimeInterval = 0.1) {
        self.chunkDuration = chunkDuration
    }

    /// Сколько блоков сэмплов было сброшено из-за переполнения буфера (норма — 0).
    public var droppedBlocks: Int { ring.dropped }

    public func stream() -> AsyncStream<AudioChunk> {
        let ring = self.ring
        let chunkDuration = self.chunkDuration
        return AsyncStream { continuation in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0,
                  let monoInput = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: inputFormat.sampleRate,
                    channels: 1,
                    interleaved: false
                  ),
                  let resampler = AudioResampler(inputFormat: monoInput) else {
                AppLog.audio.error("микрофон: некорректный входной формат")
                continuation.finish()
                return
            }

            // Real-time поток: только копируем канал 0 в кольцевой буфер. Никакого
            // ресемплинга/тяжёлых аллокаций в аудио-колбэке (иначе Core Audio overload).
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                ring.write(Array(UnsafeBufferPointer(start: channels[0], count: frames)))
            }

            // Consumer: дренируем буфер, нарезаем на кадры, отдаём наружу.
            let consumer = Task {
                let chunker = AudioChunker(sampleRate: 16_000, chunkDuration: chunkDuration)
                let cursor = TimeCursor()
                while !Task.isCancelled {
                    if let block = ring.read(), let resampled = resampler.resampleRaw(block) {
                        for frame in chunker.push(resampled) {
                            let timestamp = cursor.advance(frame.count, sampleRate: 16_000)
                            continuation.yield(AudioChunk(
                                source: .microphone,
                                sampleRate: 16_000,
                                samples: frame,
                                timestamp: timestamp
                            ))
                        }
                    } else {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                continuation.finish()
            }

            let holder = EngineHolder(engine: engine, input: input)
            do {
                engine.prepare()
                try engine.start()
                AppLog.audio.info("микрофон: захват запущен, вход \(Int(inputFormat.sampleRate)) Гц")
            } catch {
                AppLog.audio.error("микрофон: не удалось запустить движок")
                consumer.cancel()
                continuation.finish()
                return
            }

            continuation.onTermination = { _ in
                holder.input.removeTap(onBus: 0)
                holder.engine.stop()
                consumer.cancel()
            }
        }
    }
}

/// Держатель не-Sendable объектов AVFoundation для безопасного захвата в `@Sendable`
/// замыкании `onTermination`. Доступ к движку сериализован самим AVAudioEngine.
private final class EngineHolder: @unchecked Sendable {
    let engine: AVAudioEngine
    let input: AVAudioInputNode
    init(engine: AVAudioEngine, input: AVAudioInputNode) {
        self.engine = engine
        self.input = input
    }
}

/// Монотонный курсор времени: переводит счётчик сэмплов в секунды от старта.
private final class TimeCursor: @unchecked Sendable {
    private var samples = 0
    private let lock = NSLock()

    func advance(_ count: Int, sampleRate: Double) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let time = Double(samples) / sampleRate
        samples += count
        return time
    }
}
