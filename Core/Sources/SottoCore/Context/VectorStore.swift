import Foundation

/// In-memory векторное хранилище с поиском топ-K по косинусной близости.
/// Для личного объёма данных (профиль) этого достаточно; векторную БД добавим
/// только при росте данных. Векторы нормализуются при вставке (косинус = скалярное).
public struct VectorStore: Sendable {
    private var chunks: [TextChunk] = []
    private var vectors: [[Float]] = []

    public init() {}

    public var count: Int { chunks.count }

    /// Полностью заменить содержимое (чанки + соответствующие векторы).
    public mutating func replaceAll(chunks: [TextChunk], vectors: [[Float]]) {
        precondition(chunks.count == vectors.count, "число чанков и векторов должно совпадать")
        self.chunks = chunks
        self.vectors = vectors.map { Self.normalized($0) }
    }

    /// Топ-K ближайших к запросу чанков (по убыванию близости).
    public func topK(query: [Float], k: Int) -> [ScoredChunk] {
        guard !chunks.isEmpty, k > 0 else { return [] }
        let normalizedQuery = Self.normalized(query)
        let scored = zip(chunks, vectors).map { chunk, vector in
            ScoredChunk(chunk: chunk, score: Double(Self.dot(normalizedQuery, vector)))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
