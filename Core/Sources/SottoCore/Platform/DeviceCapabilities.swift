import Foundation

/// Характеристики устройства (чип, RAM) — для выбора рекомендованного профиля моделей.
/// Читаем через `sysctl`. Реальные значения уже в фазе 1 (M-серия, объём памяти).
public struct DeviceCapabilities: Sendable {
    public let chipName: String
    public let totalRAMBytes: UInt64
    public let performanceCores: Int

    public var totalRAMGB: Double { Double(totalRAMBytes) / 1_073_741_824 }

    /// Рекомендованный профиль скорость/качество по объёму памяти.
    public enum QualityTier: String, Sendable {
        case fast       // < 16 ГБ
        case balanced   // 16–32 ГБ
        case quality    // 32 ГБ+

        public var title: String {
            switch self {
            case .fast: return "быстрый"
            case .balanced: return "сбалансированный"
            case .quality: return "качественный"
            }
        }
    }

    public var recommendedTier: QualityTier {
        switch totalRAMGB {
        case ..<16: return .fast
        case 16..<32: return .balanced
        default: return .quality
        }
    }

    public static func current() -> DeviceCapabilities {
        DeviceCapabilities(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            totalRAMBytes: sysctlUInt64("hw.memsize") ?? 0,
            performanceCores: Int(sysctlUInt64("hw.perflevel0.physicalcpu") ?? 0)
        )
    }

    public init(chipName: String, totalRAMBytes: UInt64, performanceCores: Int) {
        self.chipName = chipName
        self.totalRAMBytes = totalRAMBytes
        self.performanceCores = performanceCores
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let nullIndex = buffer.firstIndex(of: 0) { buffer = Array(buffer[..<nullIndex]) }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
