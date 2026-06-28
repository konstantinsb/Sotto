import Foundation
import SwiftData
import SottoCore

/// Хранилище истории сессий (SwiftData) с шифрованием чувствительных полей (CryptoBox).
@MainActor
final class SessionStore {
    let container: ModelContainer
    private let crypto = CryptoBox.appBox()

    init() {
        let schema = Schema([StoredSession.self, StoredSegment.self, StoredSuggestion.self])
        do {
            container = try ModelContainer(for: schema)
        } catch {
            // Фолбэк в память, если постоянное хранилище недоступно.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: config)
        }
    }

    private var context: ModelContext { container.mainContext }

    /// Сохранить завершённую сессию (только если был разговор).
    func save(mode: ModeKind, startedAt: Date, finals: [TranscriptSegment], suggestions: [Suggestion], summary: String) {
        guard !finals.isEmpty else { return }
        let session = StoredSession(
            startedAt: startedAt,
            mode: mode.rawValue,
            summaryCiphertext: summary.isEmpty ? nil : crypto.encrypt(summary)
        )
        context.insert(session)
        for (index, segment) in finals.enumerated() {
            guard let cipher = crypto.encrypt(segment.text) else { continue }
            let stored = StoredSegment(source: segment.source.rawValue, textCiphertext: cipher, order: index)
            stored.session = session
            context.insert(stored)
        }
        for suggestion in suggestions {
            guard let cipher = crypto.encrypt(suggestion.text) else { continue }
            let stored = StoredSuggestion(
                textCiphertext: cipher,
                model: suggestion.model,
                latencyMs: suggestion.latencyMs,
                createdAt: Date(timeIntervalSince1970: suggestion.createdAt)
            )
            stored.session = session
            context.insert(stored)
        }
        try? context.save()
    }

    func recentSessions() -> [StoredSession] {
        let descriptor = FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func summary(of session: StoredSession) -> String? {
        session.summaryCiphertext.flatMap { crypto.decryptString($0) }
    }

    func segments(of session: StoredSession) -> [(source: AudioSource, text: String)] {
        session.segments
            .sorted { $0.order < $1.order }
            .compactMap { stored in
                guard let text = crypto.decryptString(stored.textCiphertext) else { return nil }
                return (AudioSource(rawValue: stored.source) ?? .system, text)
            }
    }

    func suggestions(of session: StoredSession) -> [String] {
        session.suggestions
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { crypto.decryptString($0.textCiphertext) }
    }

    func delete(_ session: StoredSession) {
        context.delete(session)
        try? context.save()
    }

    func deleteAll() {
        for session in recentSessions() { context.delete(session) }
        try? context.save()
    }
}
