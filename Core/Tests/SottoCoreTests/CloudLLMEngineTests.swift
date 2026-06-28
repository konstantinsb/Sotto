import XCTest
@testable import SottoCore

final class CloudLLMEngineTests: XCTestCase {
    private let config = CloudLLMConfig(
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "fast-model",
        apiKey: "secret-key"
    )

    // MARK: - Разбор SSE

    func testParseContentLine() {
        let chunk = CloudLLMEngine.parseSSE(#"data: {"choices":[{"delta":{"content":"привет"}}]}"#)
        XCTAssertEqual(chunk, .content("привет"))
    }

    func testParseDone() {
        XCTAssertEqual(CloudLLMEngine.parseSSE("data: [DONE]"), .done)
    }

    func testParseIgnoresNonData() {
        XCTAssertNil(CloudLLMEngine.parseSSE(": keep-alive comment"))
        XCTAssertNil(CloudLLMEngine.parseSSE(""))
        XCTAssertNil(CloudLLMEngine.parseSSE(#"data: {"choices":[{"delta":{}}]}"#))   // нет content
    }

    // MARK: - Тело запроса

    func testRequestBodyAndHeaders() throws {
        let request = try CloudLLMEngine.makeRequest(
            prompt: Prompt(system: "sys", user: "usr"),
            options: GenerationOptions(maxTokens: 50, temperature: 0.2),
            config: config
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "fast-model")
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(body?["max_tokens"] as? Int, 50)
        XCTAssertEqual(body?["temperature"] as? Double ?? 0, 0.2, accuracy: 0.001)

        let messages = body?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertEqual(messages?.first?["content"], "sys")
        XCTAssertEqual(messages?.last?["content"], "usr")
    }

    // MARK: - Сквозной стриминг через фейковый транспорт

    func testStreamConcatenatesContentAndStopsAtDone() async throws {
        let transport = FakeTransport(cannedLines: [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" world"}}]}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":" ignored"}}]}"#   // после DONE — игнор
        ])
        let engine = CloudLLMEngine(config: config, transport: transport)

        var output = ""
        for try await chunk in engine.generate(prompt: Prompt(system: "s", user: "u"), options: .liveHint) {
            output += chunk
        }
        XCTAssertEqual(output, "Hello world")
    }

    func testTransportErrorPropagates() async {
        struct Boom: Error {}
        let transport = FakeTransport(cannedLines: [], error: Boom())
        let engine = CloudLLMEngine(config: config, transport: transport)

        var threw = false
        do {
            for try await _ in engine.generate(prompt: Prompt(system: "s", user: "u"), options: .liveHint) {}
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "ошибка транспорта должна пробрасываться потребителю")
    }
}

/// Транспорт-фейк: выдаёт заранее заданные SSE-строки (и опционально завершается ошибкой).
private struct FakeTransport: CloudLLMTransport {
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
