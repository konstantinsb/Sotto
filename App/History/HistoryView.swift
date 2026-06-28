import SwiftUI
import SottoCore

/// Окно истории сессий: список прошлых разговоров с расшифровкой/подсказками/summary.
/// Дизайн-система Sotto (Dark-first): мастер-деталь, цветокод источников точками,
/// подсказки акцентом, токенизированная типографика.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sessions: [StoredSession] = []
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sessions, id: \.id) { session in
                        DisclosureGroup {
                            detail(session)
                        } label: {
                            row(session)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(SottoTokens.Color.borderDefault)
                    }
                }
                .scrollContentBackground(.hidden)
                .tint(SottoTokens.Color.accent)
            }
            Divider().overlay(SottoTokens.Color.borderDefault)
            HStack {
                Spacer()
                Button("Очистить историю") { confirmClear = true }
                    .buttonStyle(SottoSecondaryButtonStyle(tint: SottoTokens.Color.statusDanger))
                    .disabled(sessions.isEmpty)
            }
            .padding(SottoTokens.Spacing.l)
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(SottoTokens.Color.surfaceSolid)
        .foregroundStyle(SottoTokens.Color.textPrimary)
        .onAppear { reload() }
        .confirmationDialog("Удалить всю историю?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                env.sessionStore.deleteAll()
                reload()
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        VStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(SottoTokens.Color.textTertiary)
            Text("История пуста").font(SottoTokens.Font.title)
            Text("Завершённые живые сессии с разговором появятся здесь.")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SottoTokens.Spacing.xl)
    }

    private func reload() {
        sessions = env.sessionStore.recentSessions()
    }

    private func row(_ session: StoredSession) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xxs) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(SottoTokens.Font.bodyMed)
                .foregroundStyle(SottoTokens.Color.textPrimary)
            Text("\(ModeKind(rawValue: session.mode)?.title ?? session.mode) · \(session.segments.count) реплик")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
        }
    }

    @ViewBuilder
    private func detail(_ session: StoredSession) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            if let summary = env.sessionStore.summary(of: session) {
                SottoSectionHeader("Summary")
                Text(summary)
                    .font(SottoTokens.Font.body)
                    .foregroundStyle(SottoTokens.Color.textSecondary)
                    .textSelection(.enabled)
            }
            SottoSectionHeader("Транскрипт")
            ForEach(Array(env.sessionStore.segments(of: session).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: SottoTokens.Spacing.s) {
                    Circle()
                        .fill(sourceColor(item.source))
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    Text(item.text)
                        .font(SottoTokens.Font.caption)
                        .foregroundStyle(SottoTokens.Color.textSecondary)
                }
            }
            let suggestions = env.sessionStore.suggestions(of: session)
            if !suggestions.isEmpty {
                SottoSectionHeader("Подсказки", icon: "sparkles")
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(SottoTokens.Font.caption)
                        .foregroundStyle(SottoTokens.Color.accent)
                        .textSelection(.enabled)
                }
            }
            Button("Удалить сессию") {
                env.sessionStore.delete(session)
                reload()
            }
            .buttonStyle(SottoSecondaryButtonStyle(tint: SottoTokens.Color.statusDanger))
            .padding(.top, SottoTokens.Spacing.xs)
        }
        .padding(.vertical, SottoTokens.Spacing.xs)
    }

    /// Цветокод источника: система (собеседник) = небо, микрофон = голос (зелёный).
    private func sourceColor(_ source: AudioSource) -> Color {
        source == .system ? SottoTokens.Color.sourceScreen : SottoTokens.Color.sourceVoice
    }
}
