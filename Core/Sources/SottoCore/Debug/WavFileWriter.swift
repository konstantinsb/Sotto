import Foundation

/// Инкрементальная запись WAV (PCM16, моно). Сразу пишем заголовок-заглушку, дописываем
/// сэмплы по мере поступления, в `close()` правим размеры в заголовке. Так длинная сессия
/// не копит всё аудио в памяти.
final class WavFileWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private var dataBytes: Int = 0

    init?(url: URL, sampleRate: Int) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        self.sampleRate = sampleRate
        try? handle.write(contentsOf: Self.header(dataBytes: 0, sampleRate: sampleRate))
    }

    func append(_ samples: [Float]) {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try? handle.write(contentsOf: pcm)
        dataBytes += pcm.count
    }

    func close() {
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(dataBytes: dataBytes, sampleRate: sampleRate))
        try? handle.close()
    }

    private static func header(dataBytes: Int, sampleRate: Int) -> Data {
        let channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                          // размер fmt-чанка
        u16(1)                           // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        return d
    }
}
