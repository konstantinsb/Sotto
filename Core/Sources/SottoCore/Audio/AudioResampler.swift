@preconcurrency import AVFoundation

/// Ресемплер на базе `AVAudioConverter`: приводит входной буфер (любой аппаратный
/// формат микрофона) к целевому 16 кГц / моно / Float32 для ASR.
///
/// Один экземпляр переиспользуется на все вызовы tap — конвертер хранит внутреннее
/// состояние и сохраняет непрерывность между фрагментами.
public final class AudioResampler: @unchecked Sendable {
    public let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(inputFormat: AVAudioFormat, targetSampleRate: Double = 16_000) {
        guard inputFormat.sampleRate > 0,
              let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
    }

    /// Конвертировать сырые моно-сэмплы (во входном формате) к 16 кГц.
    /// Используется, когда ресемплинг вынесен из real-time потока: tap отдаёт
    /// `[Float]`, а оборачивание в буфер и конвертация идут в consumer'е.
    public func resampleRaw(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel[0].update(from: base, count: samples.count)
            }
        }
        return resample(input)
    }

    /// Конвертировать один входной буфер. Возвращает массив сэмплов 16 кГц моно.
    public func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let state = ConversionState()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if state.delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            state.delivered = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, let channel = output.floatChannelData else { return nil }
        let frames = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: frames))
    }
}

/// Одноразовый флаг доставки входного буфера в блок конвертера. Блок вызывается
/// синхронно внутри `convert(to:error:)` на том же потоке — гонок нет.
private final class ConversionState: @unchecked Sendable {
    var delivered = false
}
