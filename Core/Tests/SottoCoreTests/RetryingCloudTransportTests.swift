import XCTest
@testable import SottoCore

/// Ретраи облачного транспорта: rate-limit (429) и серверные 5xx — временные, повторяются;
/// квотные 429 и клиентские ошибки — нет.
final class RetryingCloudTransportTests: XCTestCase {
    private let request = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)

    // MARK: - Политика ретраев (чистые функции)

    func testRateLimit429UsesBodyHint() {
        let body = #"{"error":{"message":"Rate limit reached for gpt-4o ... Please try again in 120ms. ..."}}"#
        let delay = RetryingCloudTransport.retryDelay(
            code: 429, body: body, attempt: 0, base: .milliseconds(400), max: .seconds(3)
        )
        XCTAssertEqual(delay, .milliseconds(120), "при rate-limit берём точную подсказку «try again in N»")
    }

    func testQuota429NotRetried() {
        let body = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details."}}"#
        XCTAssertNil(
            RetryingCloudTransport.retryDelay(code: 429, body: body, attempt: 0, base: .milliseconds(400), max: .seconds(3)),
            "квотный 429 не временный — ретрай не поможет"
        )
    }

    func testServer5xxRetriesWithBackoff() {
        XCTAssertEqual(
            RetryingCloudTransport.retryDelay(code: 503, body: "", attempt: 0, base: .milliseconds(400), max: .seconds(3)),
            .milliseconds(400)
        )
        XCTAssertEqual(
            RetryingCloudTransport.retryDelay(code: 503, body: "", attempt: 1, base: .milliseconds(400), max: .seconds(3)),
            .milliseconds(800)
        )
    }

    func testBackoffCappedAtMax() {
        XCTAssertEqual(RetryingCloudTransport.backoff(attempt: 5, base: .seconds(1), max: .seconds(3)), .seconds(3))
    }

    func testNonRetryableClientCodes() {
        XCTAssertNil(RetryingCloudTransport.retryDelay(code: 400, body: "bad request", attempt: 0, base: .milliseconds(400), max: .seconds(3)))
        XCTAssertNil(RetryingCloudTransport.retryDelay(code: 401, body: "invalid key", attempt: 0, base: .milliseconds(400), max: .seconds(3)))
    }

    func testHintedDelayParsesSeconds() {
        XCTAssertEqual(RetryingCloudTransport.hintedDelay(fromBody: "Please try again in 1.5s."), .milliseconds(1500))
        XCTAssertEqual(RetryingCloudTransport.hintedDelay(fromBody: "Please try again in 250ms."), .milliseconds(250))
        XCTAssertNil(RetryingCloudTransport.hintedDelay(fromBody: "no hint here"))
    }

    // MARK: - Поведение декоратора (через фейковый inner-транспорт)

    func testRetriesThenSucceeds() async throws {
        let inner = SequencedTransport(outcomes: [
            .failure(.httpStatus(429, "Please try again in 10ms")),
            .success(["data: hi", "data: [DONE]"])
        ])
        let transport = RetryingCloudTransport(wrapping: inner, maxRetries: 2, sleep: { _ in })

        var lines: [String] = []
        for try await line in try await transport.lines(for: request) { lines.append(line) }

        XCTAssertEqual(lines, ["data: hi", "data: [DONE]"])
        let calls = await inner.callCount
        XCTAssertEqual(calls, 2, "один 429 → ровно один ретрай")
    }

    func testQuota429ThrowsWithoutRetry() async {
        let inner = SequencedTransport(outcomes: [
            .failure(.httpStatus(429, "You exceeded your current quota; check billing")),
            .success(["data: [DONE]"])
        ])
        let transport = RetryingCloudTransport(wrapping: inner, maxRetries: 2, sleep: { _ in })

        var threw = false
        do { _ = try await transport.lines(for: request) } catch { threw = true }

        XCTAssertTrue(threw)
        let calls = await inner.callCount
        XCTAssertEqual(calls, 1, "квотный 429 пробрасывается сразу, без ретраев")
    }

    func testExhaustsRetriesThenThrows() async {
        let inner = SequencedTransport(outcomes: [
            .failure(.httpStatus(503, "")),
            .failure(.httpStatus(503, "")),
            .failure(.httpStatus(503, "")),
            .success(["data: [DONE]"])
        ])
        let transport = RetryingCloudTransport(wrapping: inner, maxRetries: 2, sleep: { _ in })

        var threw = false
        do { _ = try await transport.lines(for: request) } catch { threw = true }

        XCTAssertTrue(threw)
        let calls = await inner.callCount
        XCTAssertEqual(calls, 3, "1 попытка + 2 ретрая = 3 вызова")
    }

    // MARK: - Человеко-понятные сообщения

    func testHumanMessageClassifiesQuotaVsRateLimit() {
        let quota = CloudLLMError.humanMessage(code: 429, body: "You exceeded your current quota")
        XCTAssertTrue(quota.lowercased().contains("квота"))

        let rate = CloudLLMError.humanMessage(code: 429, body: "Rate limit reached, please try again in 120ms")
        XCTAssertTrue(rate.contains("RPM"))

        let auth = CloudLLMError.humanMessage(code: 401, body: "invalid key")
        XCTAssertTrue(auth.lowercased().contains("ключ"))
    }
}

/// Транспорт-фейк: на каждый вызов отдаёт следующий запрограммированный исход —
/// ошибку из `lines(for:)` (как реальный транспорт на не-2xx) либо успешный поток строк.
private actor SequencedTransport: CloudLLMTransport {
    enum Outcome {
        case failure(CloudLLMError)
        case success([String])
    }
    private var outcomes: [Outcome]
    private(set) var callCount = 0

    init(outcomes: [Outcome]) { self.outcomes = outcomes }

    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        callCount += 1
        let outcome = outcomes.isEmpty ? .success([]) : outcomes.removeFirst()
        switch outcome {
        case .failure(let error):
            throw error
        case .success(let lines):
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        }
    }
}
