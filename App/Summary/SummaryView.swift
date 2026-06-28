import SwiftUI
import SottoCore

/// Окно summary разговора: выжимка по накопленному транскрипту (LLM).
/// Дизайн-система Sotto (Dark-first): контейнер выжимки, явное состояние генерации,
/// токенизированная типографика и кнопки.
struct SummaryView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.l) {
            header
            if env.conversation.finals.isEmpty {
                SottoBanner(kind: .info, text: "Транскрипта пока нет — запустите сессию, чтобы появился разговор для выжимки.")
            }
            summaryBody
            footer
        }
        .padding(SottoTokens.Spacing.xl)
        .frame(minWidth: 480, minHeight: 420)
        .background(SottoTokens.Color.surfaceSolid)
        .foregroundStyle(SottoTokens.Color.textPrimary)
    }

    private var header: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(SottoTokens.Color.accent)
            Text("Summary разговора").font(SottoTokens.Font.title)
            Spacer()
            if env.summaryRunning {
                HStack(spacing: SottoTokens.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("генерация…")
                        .font(SottoTokens.Font.caption)
                        .foregroundStyle(SottoTokens.Color.textTertiary)
                }
            }
        }
    }

    private var summaryBody: some View {
        ScrollView {
            Text(env.summaryText.isEmpty
                 ? "Нажмите «Сделать summary» — модель прочитает транскрипт и выдаст краткую выжимку."
                 : env.summaryText)
                .font(SottoTokens.Font.body)
                .foregroundStyle(env.summaryText.isEmpty ? SottoTokens.Color.textTertiary : SottoTokens.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sottoCard()
    }

    private var footer: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Button(env.summaryRunning ? "Остановить" : "Сделать summary") {
                if env.summaryRunning { env.cancelSummary() } else { env.summarize() }
            }
            .buttonStyle(SottoPrimaryButtonStyle())
            .disabled(env.conversation.finals.isEmpty && !env.summaryRunning)
            Spacer()
            Text("\(env.conversation.finals.count) реплик в транскрипте")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
        }
    }
}
