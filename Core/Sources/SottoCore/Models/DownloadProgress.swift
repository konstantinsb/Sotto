import Foundation

/// Прогресс скачивания модели: доля (0..1) и, если известен, размер в байтах.
/// Байты позволяют показывать «1.2 ГБ / 2.5 ГБ», когда процент «застывает» на одном
/// большом файле — так загрузка не выглядит замёрзшей.
public struct DownloadProgress: Sendable, Equatable {
    public let fraction: Double
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(fraction: Double, completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.fraction = min(1, max(0, fraction))
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = max(0, totalBytes)
    }

    /// Из `Foundation.Progress` загрузчика (HF/WhisperKit отдают байты в unit count).
    public init(_ progress: Progress) {
        self.init(
            fraction: progress.fractionCompleted,
            completedBytes: progress.completedUnitCount,
            totalBytes: progress.totalUnitCount
        )
    }

    public var percent: Int { Int((fraction * 100).rounded()) }

    /// «1.2 ГБ / 2.5 ГБ» — только если общий размер задан в байтах (≥1 МБ). Некоторые
    /// загрузчики кладут в unit count не байты (мелкие числа) — их как размер не показываем.
    public var sizeText: String? {
        guard totalBytes >= 1_000_000 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: completedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
    }
}
