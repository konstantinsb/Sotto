import XCTest
import AVFoundation
@testable import SottoCore

final class AudioChunkerTests: XCTestCase {

    func testEmitsFixedSizeChunksAndKeepsRemainder() {
        let chunker = AudioChunker(sampleRate: 16_000, chunkDuration: 0.1) // 1600 сэмплов/кадр
        XCTAssertEqual(chunker.chunkSize, 1600)

        let first = chunker.push([Float](repeating: 0.1, count: 4000))
        XCTAssertEqual(first.count, 2)                 // 4000 → 2 кадра по 1600
        XCTAssertEqual(chunker.pendingCount, 800)      // остаток 800

        let second = chunker.push([Float](repeating: 0.1, count: 800))
        XCTAssertEqual(second.count, 1)                // 800 + 800 = 1600 → 1 кадр
        XCTAssertEqual(chunker.pendingCount, 0)
    }

    func testNoChunkUntilFull() {
        let chunker = AudioChunker(sampleRate: 16_000, chunkDuration: 0.1)
        XCTAssertTrue(chunker.push([Float](repeating: 0, count: 100)).isEmpty)
        XCTAssertEqual(chunker.pendingCount, 100)
    }
}

final class EnergyVADTests: XCTestCase {

    func testSilenceIsNotSpeech() {
        let vad = EnergyVAD(threshold: 0.01, hangoverFrames: 3)
        let result = vad.process([Float](repeating: 0, count: 1600))
        XCTAssertFalse(result.isSpeech)
        XCTAssertEqual(result.rms, 0, accuracy: 1e-6)
    }

    func testLoudSignalIsSpeech() {
        let vad = EnergyVAD(threshold: 0.01, hangoverFrames: 3)
        let loud = [Float](repeating: 0.3, count: 1600)
        XCTAssertTrue(vad.process(loud).isSpeech)
    }

    func testHangoverKeepsSpeechThroughShortSilence() {
        let vad = EnergyVAD(threshold: 0.05, hangoverFrames: 3)
        let loud = [Float](repeating: 0.3, count: 1600)
        let quiet = [Float](repeating: 0.0, count: 1600)

        XCTAssertTrue(vad.process(loud).isSpeech)
        XCTAssertTrue(vad.process(quiet).isSpeech)   // hangover 1
        XCTAssertTrue(vad.process(quiet).isSpeech)   // hangover 2
        XCTAssertTrue(vad.process(quiet).isSpeech)   // hangover 3
        XCTAssertFalse(vad.process(quiet).isSpeech)  // > hangover → тишина
    }
}

final class AudioResamplerTests: XCTestCase {

    /// Синтетический буфер 48 кГц → 16 кГц должен дать примерно треть сэмплов,
    /// конечные и без падения. Проверяется чистый DSP, без аудио-железа.
    func testResamples48kTo16k() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let frames: AVAudioFrameCount = 4800 // 0.1 с при 48 кГц
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            channel[0][i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
        }

        let resampler = try XCTUnwrap(AudioResampler(inputFormat: inputFormat, targetSampleRate: 16_000))
        let output = try XCTUnwrap(resampler.resample(buffer))

        XCTAssertGreaterThan(output.count, 1200)  // ~1600 минус праймер/латентность конвертера
        XCTAssertLessThan(output.count, 1800)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
    }

    func testEmptyBufferYieldsEmpty() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 0
        let resampler = try XCTUnwrap(AudioResampler(inputFormat: format))
        XCTAssertEqual(resampler.resample(buffer)?.count, 0)
    }

    /// resampleRaw: сырые моно-сэмплы 48к → ~16к (путь, вынесенный из RT-потока).
    func testResampleRawMono48kTo16k() throws {
        let monoInput = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let resampler = try XCTUnwrap(AudioResampler(inputFormat: monoInput, targetSampleRate: 16_000))
        var samples = [Float](repeating: 0, count: 4800)
        for i in 0..<4800 { samples[i] = sinf(2 * .pi * 440 * Float(i) / 48_000) }

        let out = try XCTUnwrap(resampler.resampleRaw(samples))
        XCTAssertGreaterThan(out.count, 1200)
        XCTAssertLessThan(out.count, 1800)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testResampleRawEmpty() throws {
        let monoInput = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        let resampler = try XCTUnwrap(AudioResampler(inputFormat: monoInput))
        XCTAssertEqual(resampler.resampleRaw([])?.count, 0)
    }
}
