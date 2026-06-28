import Foundation

/// Чистка расшифровки от «галлюцинаций» Whisper.
///
/// На тишине и фоновом шуме Whisper уверенно выдаёт текст, которого не было: ютуб-титры
/// («Редактор субтитров … Корректор …»), благодарности («Спасибо за просмотр»), призывы
/// подписаться, `Amara.org`. Это не речь собеседника — иначе детектор вопроса и подсказка
/// срабатывают на пустоту. Удаляем целые предложения, содержащие такие маркеры.
public enum TranscriptSanitizer {

    /// Маркеры известных галлюцинаций (в нижнем регистре). Только однозначные фразы —
    /// одиночные «редактор»/«корректор» НЕ берём, чтобы не резать живую речь.
    static let hallucinationMarkers: [String] = [
        "редактор субтитров",
        "субтитры сделал",
        "субтитры создал",
        "субтитры предоставлены",
        "субтитры подготовлены",
        "продолжение следует",
        "спасибо за просмотр",
        "спасибо за внимание",
        "подписывайтесь на канал",
        "ставьте лайк",
        "amara.org",
        "амара.орг",
        "thanks for watching",
        "subtitles by",
        "subscribe to"
    ]

    /// Убрать предложения-галлюцинации, сохранив остальное. Если осталась пустота —
    /// вернётся пустая строка (вызывающий такой сегмент не эмитит).
    public static func stripHallucinations(_ text: String) -> String {
        let kept = splitSentences(text).filter { !isHallucination($0) }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Предложение целиком является известной галлюцинацией?
    static func isHallucination(_ sentence: String) -> Bool {
        let s = sentence.lowercased()
        return hallucinationMarkers.contains { s.contains($0) }
    }

    /// Разбить на предложения по терминаторам `.?!`. Граница — только если за знаком идёт
    /// пробел или конец строки: иначе инициалы («А.Семкин») и многоточия рвут предложение
    /// на куски, и маркер галлюцинации совпадает лишь с фрагментом.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ch == "." || ch == "?" || ch == "!" else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if next == nil || next!.isWhitespace {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}
