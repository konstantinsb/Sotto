import Foundation

/// Нарезка текста профиля на чанки. Делит по абзацам; длинные абзацы дробит по
/// предложениям, накапливая до `maxCharsPerChunk`.
public struct TextChunker: Sendable {
    public let maxCharsPerChunk: Int

    public init(maxCharsPerChunk: Int = 400) {
        self.maxCharsPerChunk = max(80, maxCharsPerChunk)
    }

    public func chunks(from text: String, sourceTitle: String) -> [TextChunk] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [TextChunk] = []
        for paragraph in paragraphs {
            if paragraph.count <= maxCharsPerChunk {
                result.append(TextChunk(text: paragraph, sourceTitle: sourceTitle))
            } else {
                result.append(contentsOf: splitLong(paragraph, sourceTitle: sourceTitle))
            }
        }
        return result
    }

    /// Дробление длинного абзаца по предложениям с накоплением до лимита.
    private func splitLong(_ paragraph: String, sourceTitle: String) -> [TextChunk] {
        let sentences = paragraph
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks: [TextChunk] = []
        var current = ""
        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + ". " + sentence
            if candidate.count > maxCharsPerChunk, !current.isEmpty {
                chunks.append(TextChunk(text: current, sourceTitle: sourceTitle))
                current = sentence
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(TextChunk(text: current, sourceTitle: sourceTitle))
        }
        return chunks
    }
}
