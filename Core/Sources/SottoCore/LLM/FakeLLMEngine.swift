import Foundation

/// Фейковый LLM: имитирует прогрев и стримит заранее заданный ответ слово за словом.
/// Позволяет в фазе 1 проверить сквозной поток токенов и появление подсказки по словам.
public struct FakeLLMEngine: LLMEngine {
    public let modelName: String
    private let perTokenDelay: Duration
    private let warmUpDelay: Duration
    private let answer: String

    public init(
        modelName: String = "fake-llm",
        perTokenDelay: Duration = .milliseconds(60),
        warmUpDelay: Duration = .milliseconds(300),
        answer: String = "Я бы реализовал дебаунс через actor: каждое новое событие отменяет предыдущую Task с Task.sleep на нужную задержку. Это даёт потокобезопасную отмену без таймеров и гонок данных."
    ) {
        self.modelName = modelName
        self.perTokenDelay = perTokenDelay
        self.warmUpDelay = warmUpDelay
        self.answer = answer
    }

    public func warmUp() async {
        try? await Task.sleep(for: warmUpDelay)
    }

    public func generate(prompt: Prompt, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        // Фейк игнорирует системный промпт и контекст, но уважает предел длины из options
        // (чтобы тесты могли проверить, что лимит прокидывается до движка).
        let allWords = answer.split(separator: " ").map(String.init)
        let words = options.maxTokens.map { Array(allWords.prefix($0)) } ?? allWords
        let perTokenDelay = self.perTokenDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in words {
                    if Task.isCancelled { break }
                    continuation.yield(word + " ")
                    do { try await Task.sleep(for: perTokenDelay) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
