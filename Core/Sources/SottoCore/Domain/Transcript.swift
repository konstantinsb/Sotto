import Foundation

/// Сегмент расшифровки: частичная гипотеза или зафиксированный (final) текст.
public struct TranscriptSegment: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let source: AudioSource
    public var text: String
    /// true — сегмент зафиксирован (пауза/конец фразы), больше не меняется.
    public var isFinal: Bool
    public let start: TimeInterval
    public var end: TimeInterval

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        text: String,
        isFinal: Bool,
        start: TimeInterval,
        end: TimeInterval
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

/// Событие движка расшифровки: частичная гипотеза (для немедленного показа) или фиксация.
public enum TranscriptEvent: Sendable {
    case partial(TranscriptSegment)
    case final(TranscriptSegment)

    public var segment: TranscriptSegment {
        switch self {
        case .partial(let segment), .final(let segment): return segment
        }
    }
}
