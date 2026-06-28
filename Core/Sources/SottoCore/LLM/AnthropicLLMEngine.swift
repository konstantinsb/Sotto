import Foundation

/// Конфигурация нативного Anthropic API (`/v1/messages`). В отличие от
/// `CloudLLMConfig` (OpenAI-совместимый `/chat/completions`), у Claude свой формат:
/// ключ в заголовке `x-api-key`, `system` — отдельное поле, `max_tokens` обязателен,
/// SSE-события другие. Прямое подключение к api.anthropic.com (нужен VPN из РФ).
public struct AnthropicLLMConfig: Sendable, Equatable {
    /// Базовый URL до версии API. По умолчанию официальный endpoint.
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    /// Версия API в заголовке `anthropic-version` (обязательный заголовок).
    public var apiVersion: String

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        model: String,
        apiKey: String,
        apiVersion: String = "2023-06-01"
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.apiVersion = apiVersion
    }
}

/// Облачный движок на нативном Anthropic Messages API (Claude). За общим протоколом
/// `LLMEngine` — подключается как любой другой движок, оркестратор/UI не меняются.
///
/// Opt-in «режим точности»: использовать ТОЛЬКО с согласия пользователя — отправляет
/// системный промпт, профиль и контекст вопроса во внешний сервис (Anthropic).
/// Намеренно БЕЗ extended thinking: для живых подсказок важен низкий TTFT, а блок
/// размышления задержал бы первый видимый токен. Sonnet 4.6 / Haiku 4.5 принимают
/// `temperature` — для моделей, где сэмплинг-параметры убраны (Opus 4.8/4.7), его
/// нужно будет не слать; текущий выбор моделей (Sonnet/Haiku) совместим.
public struct AnthropicLLMEngine: LLMEngine {
    public let modelName: String
    private let config: AnthropicLLMConfig
    private let transport: any CloudLLMTransport

    /// `max_tokens` обязателен в Anthropic API; если в `GenerationOptions` лимит не задан
    /// (`nil` = «без ограничения» в локальной модели), подставляем разумный потолок.
    static let defaultMaxTokens = 1024

    public init(config: AnthropicLLMConfig, transport: (any CloudLLMTransport)? = nil) {
        self.config = config
        self.modelName = config.model
        // Дефолтный сетевой транспорт оборачиваем ретраями (rate-limit/5xx); тесты внедряют
        // свой транспорт напрямую и ретраями не оборачиваются.
        self.transport = transport ?? RetryingCloudTransport(wrapping: URLSessionCloudTransport())
    }

    public func warmUp() async {}   // облаку прогрев не нужен — модель «горячая» на сервере

    public func generate(prompt: Prompt, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try Self.makeRequest(prompt: prompt, options: options, config: config)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lines = try await transport.lines(for: request)
                    for try await line in lines {
                        if Task.isCancelled { break }
                        switch Self.parseSSE(line) {
                        case .none: continue
                        case .stop: continuation.finish(); return
                        case .error(let message): continuation.finish(throwing: CloudLLMError.httpStatus(200, message)); return
                        case .delta(let text): if !text.isEmpty { continuation.yield(text) }
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request / SSE (чистые функции — тестируются напрямую)

    enum SSEChunk: Equatable { case delta(String); case stop; case error(String) }

    static func makeRequest(prompt: Prompt, options: GenerationOptions, config: AnthropicLLMConfig) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens ?? defaultMaxTokens,
            "stream": true,
            "temperature": Double(options.temperature),
            // system — отдельное top-level поле (не сообщение с role:"system").
            "system": prompt.system,
            "messages": [
                ["role": "user", "content": prompt.user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Разобрать одну SSE-строку Anthropic-стрима. `nil` — строка без полезной нагрузки
    /// (пустая, `event:`-строка, ping, неизвестный тип); `.stop` — конец потока;
    /// `.error` — серверная ошибка в потоке (HTTP 200 + `type:"error"`).
    static func parseSSE(_ rawLine: String) -> SSEChunk? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return nil }   // event:-строки и пустые игнорируем
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .delta(text)
        case "message_stop":
            return .stop
        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "неизвестная ошибка"
            return .error(message)
        default:
            // message_start, content_block_start/stop, message_delta, ping — без текста
            return nil
        }
    }
}
