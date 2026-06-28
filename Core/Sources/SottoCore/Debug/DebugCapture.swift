import Foundation

/// Отладочная запись сессии для оценки качества расшифровки.
///
/// Пишет в папку сессии:
/// - `system.wav` / `microphone.wav` — ровно то аудио (16 кГц моно), что уходит в Whisper;
/// - `transcript.jsonl` — поток событий: партиалы, финалы, обнаруженные вопросы, подсказки,
///   каждый с временной меткой `t` (секунды от старта).
///
/// Потом этот WAV можно перетранскрибировать эталоном (большая модель / вручную) и сравнить
/// с тем, что выдала живая расшифровка — видно, где теряется качество: в самом аудио
/// (плохой захват/ресемплинг) или в распознавании.
public actor DebugCapture {
    public nonisolated let directory: URL
    private var writers: [AudioSource: WavFileWriter] = [:]
    private var log: FileHandle?
    private let startedAt: Date

    /// Создаёт папку `<baseDirectory>/<folderName>/`. Возвращает nil, если не удалось.
    public init?(baseDirectory: URL, startedAt: Date, folderName: String) {
        let dir = baseDirectory.appending(path: folderName, directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        self.directory = dir
        self.startedAt = startedAt
        let logURL = dir.appending(path: "transcript.jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        self.log = try? FileHandle(forWritingTo: logURL)
    }

    public func appendAudio(_ samples: [Float], source: AudioSource, sampleRate: Int) {
        if writers[source] == nil {
            writers[source] = WavFileWriter(
                url: directory.appending(path: "\(source.rawValue).wav"),
                sampleRate: sampleRate
            )
        }
        writers[source]?.append(samples)
    }

    public func logTranscript(_ event: TranscriptEvent) {
        switch event {
        case .partial(let s):
            write(["type": "partial", "source": s.source.rawValue, "text": s.text, "start": s.start, "end": s.end])
        case .final(let s):
            write(["type": "final", "source": s.source.rawValue, "text": s.text, "start": s.start, "end": s.end])
        }
    }

    public func logQuestion(_ text: String) {
        write(["type": "question", "text": text])
    }

    public func logSuggestion(_ text: String, latencyMs: Int?) {
        write(["type": "suggestion", "text": text, "latencyMs": latencyMs ?? -1])
    }

    public func finish() {
        for writer in writers.values { writer.close() }
        writers.removeAll()
        try? log?.close()
        log = nil
    }

    private func write(_ object: [String: Any]) {
        var entry = object
        entry["t"] = Date().timeIntervalSince(startedAt)
        guard let log,
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else { return }
        try? log.write(contentsOf: data)
        try? log.write(contentsOf: Data([0x0a]))
    }
}
