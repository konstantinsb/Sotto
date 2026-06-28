@preconcurrency import AVFoundation
import CoreAudio

/// Захват системного звука (собеседника) через Core Audio process taps (macOS 14.4+).
///
/// Преимущество перед ScreenCaptureKit: НЕ требует разрешения «Запись экрана» —
/// использует отдельный audio-TCC (`NSAudioCaptureUsageDescription`). Глобальный tap
/// (весь системный вывод) → приватное aggregate-устройство → IOProc на real-time
/// потоке копирует сэмплы в `RingBuffer` (не ждёт); consumer ресемплит в 16 кГц.
///
/// Источник API: insidegui/AudioCap. Известные нюансы taps: формат ~48 кГц float,
/// нет публичного API запросить разрешение (промпт при первом захвате).
public final class SystemAudioCapture: AudioCapturing, @unchecked Sendable {
    private let chunkDuration: TimeInterval
    private let onSetupError: (@Sendable (String) -> Void)?
    private let ring = RingBuffer<[Float]>(capacity: 64)

    public init(chunkDuration: TimeInterval = 0.1, onSetupError: (@Sendable (String) -> Void)? = nil) {
        self.chunkDuration = chunkDuration
        self.onSetupError = onSetupError
    }

    public var droppedBlocks: Int { ring.dropped }

    public func stream() -> AsyncStream<AudioChunk> {
        let ring = self.ring
        let chunkDuration = self.chunkDuration
        let onSetupError = self.onSetupError
        return AsyncStream { continuation in
            let resources = TapResources()

            // 1. UID дефолтного устройства вывода (main sub-device агрегата).
            guard let outputUID = Self.defaultOutputDeviceUID() else {
                AppLog.audio.error("системный звук: нет дефолтного устройства вывода")
                onSetupError?("Не найдено устройство вывода звука.")
                continuation.finish(); return
            }

            // 2. Глобальный tap всего системного вывода (никого не исключаем).
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .unmuted   // не глушим вывод — пользователь слышит звонок

            var tapID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(tapDescription, &tapID) == noErr else {
                AppLog.audio.error("системный звук: не удалось создать tap (нет разрешения?)")
                onSetupError?("Нет доступа к системному звуку. Разрешите запись звука: Системные настройки → Конфиденциальность и безопасность → Запись звука.")
                continuation.finish(); return
            }
            resources.tapID = tapID

            // 3. Формат tap (частота/каналы) для ресемплинга.
            guard let asbd = Self.tapStreamFormat(tapID), asbd.mSampleRate > 0 else {
                AppLog.audio.error("системный звук: не удалось прочитать формат tap")
                Self.teardown(resources); continuation.finish(); return
            }
            let sampleRate = asbd.mSampleRate
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

            // 4. Приватное aggregate-устройство с tap'ом.
            let aggregateUID = UUID().uuidString
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Sotto-SystemTap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]]
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr else {
                AppLog.audio.error("системный звук: не удалось создать aggregate-устройство")
                Self.teardown(resources); continuation.finish(); return
            }
            resources.aggregateID = aggregateID

            // 5. IOProc: на real-time потоке копируем канал 0 в кольцевой буфер.
            let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
                let bufferList = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inInputData)
                )
                guard let buffer = bufferList.first,
                      let raw = buffer.mData else { return }
                let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard floatCount > 0 else { return }
                let pointer = raw.assumingMemoryBound(to: Float.self)

                let mono: [Float]
                if nonInterleaved || channels == 1 {
                    mono = Array(UnsafeBufferPointer(start: pointer, count: floatCount))
                } else {
                    // Чередующиеся каналы — берём канал 0.
                    let frames = floatCount / channels
                    var result = [Float](); result.reserveCapacity(frames)
                    for i in 0..<frames { result.append(pointer[i * channels]) }
                    mono = result
                }
                ring.write(mono)
            }

            var procID: AudioDeviceIOProcID?
            let queue = DispatchQueue(label: "com.konstantin.sotto.systemtap")
            guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock) == noErr,
                  let procID else {
                AppLog.audio.error("системный звук: не удалось создать IOProc")
                Self.teardown(resources); continuation.finish(); return
            }
            resources.procID = procID

            // 6. Consumer: ресемплинг (вне RT) → нарезка → выдача.
            guard let monoInput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                  let resampler = AudioResampler(inputFormat: monoInput) else {
                Self.teardown(resources); continuation.finish(); return
            }
            let consumer = Task {
                let chunker = AudioChunker(sampleRate: 16_000, chunkDuration: chunkDuration)
                let cursor = TimeCursor()
                while !Task.isCancelled {
                    if let block = ring.read(), let resampled = resampler.resampleRaw(block) {
                        for frame in chunker.push(resampled) {
                            let timestamp = cursor.advance(frame.count, sampleRate: 16_000)
                            continuation.yield(AudioChunk(source: .system, sampleRate: 16_000, samples: frame, timestamp: timestamp))
                        }
                    } else {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                continuation.finish()
            }

            guard AudioDeviceStart(aggregateID, procID) == noErr else {
                AppLog.audio.error("системный звук: не удалось запустить устройство")
                consumer.cancel(); Self.teardown(resources); continuation.finish(); return
            }
            AppLog.audio.info("системный звук: захват запущен, вход \(Int(sampleRate)) Гц")

            continuation.onTermination = { _ in
                consumer.cancel()
                Self.teardown(resources)
            }
        }
    }

    // MARK: - Core Audio помощники

    private final class TapResources: @unchecked Sendable {
        var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
    }

    private static func teardown(_ resources: TapResources) {
        if resources.aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID = resources.procID {
                AudioDeviceStop(resources.aggregateID, procID)
                AudioDeviceDestroyIOProcID(resources.aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(resources.aggregateID)
        }
        if resources.tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(resources.tapID)
        }
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }
}

/// Монотонный курсор времени (как в MicrophoneCapture).
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
