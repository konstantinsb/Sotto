import Foundation

/// Декоратор транспорта: на ВРЕМЕННЫХ ответах провайдера повторяет запрос с задержкой,
/// прежде чем отдать ошибку наверх. Облачные API отдают `429` при превышении лимита
/// запросов/токенов в минуту (RPM/TPM) с подсказкой «try again in N» — один-два тихих
/// ретрая убирают «моргание» красной ошибкой на живых подсказках. Серверные `5xx` —
/// тоже временные, ретраятся с экспоненциальным backoff.
///
/// **Что НЕ ретраится:** квотные `429` («exceeded your current quota» / billing) — это не
/// временно, повтор лишь зря жжёт запросы; и любые не-сетевые ошибки. Решение принимается
/// по телу ответа (`CloudLLMError.httpStatus`), которое наполняет `URLSessionCloudTransport`.
///
/// Ретраит только ошибки, выброшенные ДО начала стрима (HTTP-статус проверяется до отдачи
/// потока). Ошибки в середине стрима (частично полученный ответ) не повторяются — их нельзя
/// безопасно «переиграть».
public struct RetryingCloudTransport: CloudLLMTransport {
    private let inner: any CloudLLMTransport
    private let maxRetries: Int
    private let baseDelay: Duration
    private let maxDelay: Duration
    /// Инъекция сна — в тестах подменяется на no-op, чтобы не ждать реального времени.
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        wrapping inner: any CloudLLMTransport,
        maxRetries: Int = 2,
        baseDelay: Duration = .milliseconds(400),
        maxDelay: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.inner = inner
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
    }

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        var attempt = 0
        while true {
            do {
                return try await inner.lines(for: request)
            } catch let error as CloudLLMError {
                guard case .httpStatus(let code, let body) = error,
                      attempt < maxRetries,
                      let wait = Self.retryDelay(
                          code: code, body: body, attempt: attempt,
                          base: baseDelay, max: maxDelay
                      )
                else { throw error }
                try await sleep(wait)
                attempt += 1
            }
        }
    }

    // MARK: - Политика ретраев (чистые функции — тестируются напрямую)

    /// Задержка перед очередным ретраем, либо `nil` — НЕ ретраить (ошибка не временная).
    static func retryDelay(code: Int, body: String, attempt: Int, base: Duration, max: Duration) -> Duration? {
        // Серверные/таймаутные коды — временные, простой backoff.
        if [408, 425, 500, 502, 503, 504].contains(code) {
            return backoff(attempt: attempt, base: base, max: max)
        }
        if code == 429 {
            let lower = body.lowercased()
            // Квота/биллинг — не временно: повтор не поможет, только жжёт лимит.
            if lower.contains("quota") || lower.contains("insufficient_quota") || lower.contains("billing") {
                return nil
            }
            // Rate limit: берём точную подсказку «try again in N» из тела, иначе backoff.
            if let hint = hintedDelay(fromBody: body) { return Swift.min(hint, max) }
            return backoff(attempt: attempt, base: base, max: max)
        }
        return nil
    }

    /// Экспоненциальный backoff `base · 2^attempt` с потолком `max`.
    static func backoff(attempt: Int, base: Duration, max: Duration) -> Duration {
        let scaled = base * (1 << attempt)   // 1, 2, 4, …
        return scaled > max ? max : scaled
    }

    /// Вытаскивает задержку из тела OpenAI-совместимого `429`: «Please try again in 120ms»
    /// или «… in 1.5s». `nil` — подсказки нет (тогда вызывающий берёт backoff).
    static func hintedDelay(fromBody body: String) -> Duration? {
        guard let range = body.range(of: "try again in ", options: .caseInsensitive) else { return nil }
        let tail = body[range.upperBound...]
        var number = ""
        var idx = tail.startIndex
        while idx < tail.endIndex, tail[idx].isNumber || tail[idx] == "." {
            number.append(tail[idx])
            idx = tail.index(after: idx)
        }
        guard let value = Double(number) else { return nil }
        let unit = tail[idx...].trimmingCharacters(in: .whitespaces).lowercased()
        if unit.hasPrefix("ms") { return .milliseconds(Int(value)) }
        if unit.hasPrefix("s") { return .milliseconds(Int(value * 1000)) }
        return nil
    }
}
