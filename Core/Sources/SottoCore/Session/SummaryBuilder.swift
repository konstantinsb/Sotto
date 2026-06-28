import Foundation

/// Сборка промпта для summary разговора (пост-анализ / режим meetingSummarizer).
/// Берёт зафиксированные сегменты транскрипта и просит LLM выжимку.
public struct SummaryBuilder: Sendable {
    public let maxTranscriptChars: Int

    public init(maxTranscriptChars: Int = 6000) {
        self.maxTranscriptChars = max(500, maxTranscriptChars)
    }

    public func build(transcript: [TranscriptSegment], mode: ModeKind) -> Prompt {
        let system = "Ты — ассистент, который делает краткое summary разговора по-русски, чётко и по делу."

        let lines = transcript.map { segment -> String in
            let who = segment.source == .system ? "Собеседник" : "Я"
            return "\(who): \(segment.text)"
        }
        // Последние реплики важнее — обрезаем с начала, если длинно.
        let joined = lines.joined(separator: "\n")
        let trimmed = String(joined.suffix(maxTranscriptChars))

        let user = """
        Разговор (режим: \(mode.title)):
        \(trimmed.isEmpty ? "(пусто)" : trimmed)

        Сделай краткое summary в формате:
        1. Ключевые темы.
        2. Решения и договорённости.
        3. Задачи и следующие шаги.
        """
        return Prompt(system: system, user: user)
    }
}
