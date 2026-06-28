import XCTest
@testable import SottoCore

final class AnthropicLLMEngineTests: XCTestCase {
    private let config = AnthropicLLMConfig(
        baseURL: URL(string: "https://api.anthropic.com")!,
        model: "claude-sonnet-4-6",
        apiKey: "sk-ant-secret"
    )

    // MARK: - Разбор SSE (нативный формат Anthropic)

    func testParseTextDelta() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"привет"}}"#
        XCTAssertEqual(AnthropicLLMEngine.parseSSE(line), .delta("привет"))
    }

    func testParseMessageStop() {
        XCTAssertEqual(AnthropicLLMEngine.parseSSE(#"data: {"type":"message_stop"}"#), .stop)
    }

    func testParseError() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(AnthropicLLMEngine.parseSSE(line), .error("Overloaded"))
    }

    func testParseIgnoresNonTextEvents() {
        XCTAssertNil(AnthropicLLMEngine.parseSSE("event: content_block_delta"))   // event:-строка
        XCTAssertNil(AnthropicLLMEngine.parseSSE(""))
        XCTAssertNil(AnthropicLLMEngine.parseSSE(#"data: {"type":"message_start","message":{}}"#))
        XCTAssertNil(AnthropicLLMEngine.parseSSE(#"data: {"type":"ping"}"#))
        // thinking_delta — не текст ответа, не отдаём
        XCTAssertNil(AnthropicLLMEngine.parseSSE(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"..."}}"#))
    }

    // MARK: - Тело запроса и заголовки

    func testRequestBodyAndHeaders() throws {
        let request = try AnthropicLLMEngine.makeRequest(
            prompt: Prompt(system: "sys", user: "usr"),
            options: GenerationOptions(maxTokens: 50, temperature: 0.2),
            config: config
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(body?["max_tokens"] as? Int, 50)
        XCTAssertEqual(body?["temperature"] as? Double ?? 0, 0.2, accuracy: 0.001)
        // system — отдельное поле, НЕ сообщение
        XCTAssertEqual(body?["system"] as? String, "sys")
        let messages = body?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"], "user")
        XCTAssertEqual(messages?.first?["content"], "usr")
    }

    func testRequestSuppliesDefaultMaxTokensWhenUnbounded() throws {
        let request = try AnthropicLLMEngine.makeRequest(
            prompt: Prompt(system: "s", user: "u"),
            options: .unbounded,   // maxTokens == nil
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["max_tokens"] as? Int, AnthropicLLMEngine.defaultMaxTokens)
    }

    // MARK: - Сквозной стриминг через фейковый транспорт

    func testStreamConcatenatesDeltasAndStops() async throws {
        let transport = FakeAnthropicTransport(cannedLines: [
            #"data: {"type":"message_start","message":{}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}"#,
            #"data: {"type":"message_stop"}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" ignored"}}"#  // после stop — игнор
        ])
        let engine = AnthropicLLMEngine(config: config, transport: transport)

        var output = ""
        for try await chunk in engine.generate(prompt: Prompt(system: "s", user: "u"), options: .liveHint) {
            output += chunk
        }
        XCTAssertEqual(output, "Hello world")
    }

    func testStreamErrorEventPropagates() async {
        let transport = FakeAnthropicTransport(cannedLines: [
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        ])
        let engine = AnthropicLLMEngine(config: config, transport: transport)

        var threw = false
        do {
            for try await _ in engine.generate(prompt: Prompt(system: "s", user: "u"), options: .liveHint) {}
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "событие error в потоке должно пробрасываться как сбой")
    }
}

/// Транспорт-фейк: выдаёт заранее заданные SSE-строки (и опционально завершается ошибкой).
private struct FakeAnthropicTransport: CloudLLMTransport {
    let cannedLines: [String]
    var error: Error?

    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let cannedLines = self.cannedLines
        let error = self.error
        return AsyncThrowingStream { continuation in
            let task = Task {
                for line in cannedLines {
                    if Task.isCancelled { break }
                    continuation.yield(line)
                }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
