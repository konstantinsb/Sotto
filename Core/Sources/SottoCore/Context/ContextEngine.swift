import Foundation

/// Реальный движок персонального контекста (RAG): профиль → чанки → эмбеддинги →
/// топ-K по косинусной близости. Заменяет `FakeContextEngine`. Эмбеддинги профиля
/// считаются один раз и кэшируются в `VectorStore`.
public actor ContextEngine: ContextProviding {
    private let embedder: any TextEmbedder
    private let chunker: TextChunker
    private let profile: UserProfile
    private let corpus: QACorpus
    private var store = VectorStore()
    private var indexed = false

    // LRU-кэш эмбеддингов запросов: повторяющиеся вопросы (а в живой сессии один и тот же
    // вопрос часто приходит сначала спекулятивно на партиале, потом на финале) не платят
    // повторный форвард-пасс эмбеддера на критическом пути.
    private var queryCache: [String: [Float]] = [:]
    private var queryCacheOrder: [String] = []
    private let queryCacheLimit: Int

    public init(
        profile: UserProfile,
        corpus: QACorpus = .empty,
        embedder: any TextEmbedder,
        chunker: TextChunker = TextChunker(),
        queryCacheLimit: Int = 64
    ) {
        self.profile = profile
        self.corpus = corpus
        self.embedder = embedder
        self.chunker = chunker
        self.queryCacheLimit = max(1, queryCacheLimit)
    }

    public func warmUp() async {
        do {
            try await embedder.warmUp()
            try await indexProfile()
        } catch {
            AppLog.session.error("ContextEngine: прогрев не удался — \(error.localizedDescription, privacy: .public)")
        }
    }

    public func topK(for query: String, k: Int) async -> [ContextSnippet] {
        if !indexed { try? await indexProfile() }
        guard store.count > 0, k > 0 else { return [] }
        guard let queryVector = await cachedEmbed(query), !queryVector.isEmpty else { return [] }
        return store.topK(query: queryVector, k: k).map {
            ContextSnippet(text: $0.chunk.text, score: $0.score, sourceTitle: $0.chunk.sourceTitle)
        }
    }

    /// Эмбеддинг запроса с LRU-кэшем по нормализованному тексту. Промах — считаем и кладём;
    /// при переполнении вытесняем самый старый ключ.
    private func cachedEmbed(_ query: String) async -> [Float]? {
        let key = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, let cached = queryCache[key] {
            touch(key)
            return cached
        }
        guard let vector = try? await embedder.embed(query), !vector.isEmpty else { return nil }
        guard !key.isEmpty else { return vector }
        queryCache[key] = vector
        queryCacheOrder.append(key)
        if queryCacheOrder.count > queryCacheLimit {
            let evict = queryCacheOrder.removeFirst()
            queryCache[evict] = nil
        }
        return vector
    }

    /// Передвинуть ключ в конец очереди использования (most-recently-used).
    private func touch(_ key: String) {
        guard let idx = queryCacheOrder.firstIndex(of: key) else { return }
        queryCacheOrder.remove(at: idx)
        queryCacheOrder.append(key)
    }

    public func unload() async {
        await embedder.unload()
    }

    /// Один раз: нарезать профиль И базу вопросов на чанки и посчитать их эмбеддинги.
    private func indexProfile() async throws {
        guard !indexed else { return }
        var chunks: [TextChunk] = []
        // Профиль кандидата + база типовых Q&A индексируются в один store: топ-K по близости
        // достаёт релевантное из обоих (персональный контекст и канонические ответы).
        // Профиль режем чанкером (секции длинные); каждую Q&A-запись держим ОДНИМ чанком —
        // иначе чанкер разделил бы «Вопрос» и «Ответ», и матч по вопросу не принёс бы ответ.
        for source in profile.sources where !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(contentsOf: chunker.chunks(from: source.text, sourceTitle: source.title))
        }
        for entry in corpus.entries where !entry.indexedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(TextChunk(text: entry.indexedText, sourceTitle: "Q&A: \(entry.topic)"))
        }
        guard !chunks.isEmpty else {
            indexed = true
            return
        }
        let vectors = try await embedder.embed(chunks.map(\.text))
        store.replaceAll(chunks: chunks, vectors: vectors)
        indexed = true
        AppLog.session.info("ContextEngine: проиндексировано чанков — \(chunks.count)")
    }
}
