import Foundation

/// Конфигурация облачного LLM (OpenAI-совместимый `/chat/completions`: Groq, OpenAI,
/// OpenRouter, Together и т.п.). Ключ НЕ хранится в коде — приходит из настроек/окружения.
public struct CloudLLMConfig: Sendable, Equatable {
    /// Базовый URL до версии API, напр. `https://api.groq.com/openai/v1`.
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    /// Доп. заголовки (для прокси/гейтвеев).
    public var extraHeaders: [String: String]

    public init(baseURL: URL, model: String, apiKey: String, extraHeaders: [String: String] = [:]) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
    }
}

/// Транспорт строкового SSE-потока — абстракция над сетью (в тестах подменяется фейком,
/// чтобы парсинг SSE и стриминг проверялись без реальных сетевых вызовов).
public protocol CloudLLMTransport: Sendable {
    /// Выполнить запрос и отдать поток СТРОК тела ответа (по разделителю новой строки).
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error>
}

public enum CloudLLMError: Error, LocalizedError {
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return Self.humanMessage(code: code, body: body)
        }
    }

    /// Человеко-понятная причина с конкретным действием вместо сырого JSON провайдера.
    /// Неизвестные коды откатываются на исходный текст ответа.
    static func humanMessage(code: Int, body: String) -> String {
        let lower = body.lowercased()
        switch code {
        case 401, 403:
            return "Облако отклонило API-ключ (HTTP \(code)) — проверьте ключ и доступ к модели."
        case 429 where lower.contains("quota") || lower.contains("insufficient_quota") || lower.contains("billing"):
            return "Закончилась квота облачного провайдера — пополните баланс API (это отдельный платёж, не подписка ChatGPT/claude.ai)."
        case 429:
            return "Лимит запросов облака (RPM/TPM) превышен. Повторяем автоматически; если повторяется — смените модель (напр. gpt-4o-mini) или поднимите тариф."
        case 500...599:
            return "Облако временно недоступно (HTTP \(code)) — сбой на стороне провайдера, пробуем ещё раз."
        default:
            return "Облачный LLM вернул HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// Облачный движок генерации за общим протоколом `LLMEngine`: стримит токены из
/// OpenAI-совместимого endpoint. Подключается как любой другой движок — `SessionActor`,
/// `ScreenAssistActor` и UI не меняются (зависят только от `LLMEngine`).
///
/// Опция «режим точности/слабого железа»: использовать ТОЛЬКО с согласия пользователя —
/// отправляет системный промпт, профиль и контекст вопроса во внешний сервис.
public struct CloudLLMEngine: LLMEngine {
    public let modelName: String
    private let config: CloudLLMConfig
    private let transport: any CloudLLMTransport

    public init(config: CloudLLMConfig, transport: (any CloudLLMTransport)? = nil) {
        self.config = config
        self.modelName = config.model
        // Дефолтный сетевой транспорт оборачиваем ретраями (rate-limit/5xx); тесты внедряют
        // свой транспорт напрямую и ретраями не оборачиваются.
        self.transport = transport ?? RetryingCloudTransport(wrapping: URLSessionCloudTransport())
    }

    public func warmUp() async {}   // облаку прогрев не нужен — модель уже «горячая» на сервере

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
                        case .done: continuation.finish(); return
                        case .content(let text): if !text.isEmpty { continuation.yield(text) }
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

    enum SSEChunk: Equatable { case content(String); case done }

    static func makeRequest(prompt: Prompt, options: GenerationOptions, config: CloudLLMConfig) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in config.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }

        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "temperature": Double(options.temperature),
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user]
            ]
        ]
        if let maxTokens = options.maxTokens { body["max_tokens"] = maxTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Разобрать одну SSE-строку OpenAI-совместимого стрима. `nil` — строка без полезной
    /// нагрузки (пустая, комментарий, неизвестный формат); `.done` — конец потока.
    static func parseSSE(_ rawLine: String) -> SSEChunk? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return .content(content)
    }
}

/// Сетевой транспорт на URLSession: построчное чтение тела (SSE) по мере прихода байтов.
public struct URLSessionCloudTransport: CloudLLMTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
            throw CloudLLMError.httpStatus(http.statusCode, body)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
