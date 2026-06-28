import Foundation

/// Стримовый фильтр, вырезающий ведущий блок «рассуждений» `<think>…</think>`.
///
/// Qwen3 даже с маркером `/no_think` эмитит ПУСТОЙ блок `<think>\n\n</think>` в начале
/// ответа — без вырезания он попадал в подсказку как мусор. Фильтр кормят чанками потока;
/// он отдаёт уже очищенный текст. Блок может прийти разорванным между чанками, поэтому
/// держим небольшой буфер, пока не увидим `</think>` (или не убедимся, что блока нет).
public struct ThinkTagStripper: Sendable {
    private static let open = "<think>"
    private static let close = "</think>"

    private var done = false        // блок пройден или его нет — дальше пропускаем как есть
    private var buffer = ""

    public init() {}

    /// Подать очередной чанк; вернуть то, что уже можно показать (может быть пустым).
    public mutating func feed(_ chunk: String) -> String {
        if done { return chunk }
        buffer += chunk

        if let range = buffer.range(of: Self.close) {
            done = true
            let after = buffer[range.upperBound...].drop(while: { $0 == "\n" || $0 == "\r" || $0 == " " })
            buffer = ""
            return String(after)
        }
        // Буфер не является началом тега <think> и не содержит его — блока нет, отдаём как есть.
        if !Self.open.hasPrefix(buffer) && !buffer.contains("<think") {
            done = true
            defer { buffer = "" }
            return buffer
        }
        return ""   // ещё внутри блока или не определились — ждём ещё
    }

    /// Доотдать остаток (например, короткий ответ без блока, не достигший порога решения).
    public mutating func finish() -> String {
        guard !done else { return "" }
        done = true
        defer { buffer = "" }
        return buffer
    }
}
