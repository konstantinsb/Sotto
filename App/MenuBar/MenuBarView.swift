import SwiftUI
import SottoCore

/// Содержимое меню в строке состояния: статус, железо, управление сессией и окном.
/// Дизайн-система Sotto (`SottoTokens`, Dark-first): стабильная зона статуса в шапке +
/// сгруппированные строки с иконками (Сессия / Окна / Контекст / Система), primary-старт.
/// Рендерится в `.menuBarExtraStyle(.window)`, поэтому кастомный фон/цвета применяются.
struct MenuBarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            header
            if let progress = env.downloadProgress { downloadRow(progress) }
            divider
            sessionSection
            divider
            windowsSection
            divider
            contextSection
            divider
            systemSection
        }
        .padding(SottoTokens.Spacing.l)
        .frame(width: 300)
        .background(SottoTokens.Color.surfaceSolid)
        .foregroundStyle(SottoTokens.Color.textPrimary)
    }

    // MARK: - Шапка / стабильная зона статуса

    private var header: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SottoTokens.Color.accent)
            Text("Sotto").font(SottoTokens.Font.title)
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: SottoTokens.Spacing.s) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            Text(env.conversation.sessionState.title)
                .font(SottoTokens.Font.captionMed)
                .foregroundStyle(SottoTokens.Color.textSecondary)
        }
        .padding(.horizontal, SottoTokens.Spacing.m)
        .padding(.vertical, SottoTokens.Spacing.xxs)
        .background(Capsule().fill(SottoTokens.Color.surfaceRaised))
    }

    // MARK: - Группы

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
            sectionLabel("Сессия")
            if env.isRunning {
                PrimaryRow(icon: "stop.fill", title: "Остановить сессию",
                           tint: SottoTokens.Color.statusDanger) { env.stop() }
            } else {
                PrimaryRow(icon: "play.fill", title: "Старт встречи") { env.startLive() }
                    .help("Живая сессия: системный звук собеседника")
            }
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
            sectionLabel("Окна")
            MenuRow(icon: "clock.arrow.circlepath", title: "История") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(icon: "list.bullet.rectangle", title: "Summary разговора") {
                openWindow(id: "summary")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(icon: "person.crop.rectangle", title: "Профиль · контекст") {
                openWindow(id: "profile")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(icon: "macwindow.on.rectangle", title: "Оверлей: показать/скрыть") {
                env.toggleOverlayVisibility()
            }
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.s) {
            sectionLabel("Контекст")
            deviceInfo
            if env.library.profiles.count > 1 { profilePicker }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
            sectionLabel("Система")
            MenuRow(
                icon: env.micTestRunning ? "mic.fill" : "mic",
                title: env.micTestRunning ? "Остановить тест микрофона" : "Тест микрофона",
                tint: env.micTestRunning ? SottoTokens.Color.sourceVoice : SottoTokens.Color.textSecondary
            ) { env.toggleMicTest() }
            micDiagnostics
            if let summary = env.lastEvalSummary { evalRow(summary) }
            SettingsRow()
            MenuRow(icon: "power", title: "Выйти",
                    tint: SottoTokens.Color.statusDanger) { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Контекст: железо + профиль

    private var deviceInfo: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundStyle(SottoTokens.Color.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(env.device.chipName)
                    .font(SottoTokens.Font.captionMed)
                    .foregroundStyle(SottoTokens.Color.textSecondary)
                Text("RAM \(Int(env.device.totalRAMGB.rounded())) ГБ · профиль: \(env.device.recommendedTier.title)")
                    .font(SottoTokens.Font.caption)
                    .foregroundStyle(SottoTokens.Color.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SottoTokens.Spacing.m)
    }

    /// Быстрое переключение активного профиля (контекста) из меню — до старта сессии.
    private var profilePicker: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: "person.2")
                .font(.system(size: 12))
                .foregroundStyle(SottoTokens.Color.textTertiary)
                .frame(width: 18)
            Picker("Профиль", selection: profileBinding) {
                ForEach(env.library.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(SottoTokens.Color.accent)
        }
        .padding(.horizontal, SottoTokens.Spacing.m)
    }

    private var profileBinding: Binding<UUID> {
        Binding(
            get: { env.library.selectedID ?? env.library.profiles.first?.id ?? UUID() },
            set: { env.selectProfile(id: $0) }
        )
    }

    // MARK: - Загрузка моделей

    private func downloadRow(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
            HStack(spacing: SottoTokens.Spacing.m) {
                ProgressView().controlSize(.small)   // всегда крутится — загрузка жива
                // Определённый бар показываем только когда прогресс реально растёт.
                // Parakeet (FluidAudio) не отдаёт инкрементальный прогресс — там
                // fraction == 0 всю загрузку, и пустой бар выглядел бы «замёрзшим».
                if progress.fraction > 0 {
                    ProgressView(value: progress.fraction).tint(SottoTokens.Color.accent)
                }
            }
            Text(downloadCaption(progress))
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SottoTokens.Spacing.m)
    }

    private func downloadCaption(_ progress: DownloadProgress) -> String {
        // Процент показываем только когда он осмысленно растёт. При fraction == 0 без байтов
        // (Parakeet/FluidAudio не отдаёт инкрементальный прогресс) «— 0%» выглядит как
        // зависание — вместо него просто «Загрузка модели…».
        var line = env.downloadLabel
        if progress.fraction > 0 { line += " — \(progress.percent)%" }
        if let size = progress.sizeText { line += " · \(size)" }
        let status = progress.percent >= 100
            ? "\nГотовлю модель…"
            : (progress.fraction > 0 ? "\nИдёт загрузка, не закрывай." : "\nЗагрузка модели… (может занять пару минут), не закрывай.")
        return line + status
    }

    // MARK: - Диагностика микрофона / оценка расшифровки

    @ViewBuilder
    private var micDiagnostics: some View {
        if env.micPermissionDenied && env.isRunning {
            // Микрофон опционален: сессия идёт на системном звуке (собеседник). Не пугаем
            // красной «ошибкой» — это деградация, а не сбой.
            Text("Микрофон отключён (нет доступа) — подсказки по собеседнику работают. Доступ: Системные настройки → Конфиденциальность → Микрофон.")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SottoTokens.Spacing.m)
        } else if env.micPermissionDenied {
            Text("Доступ к микрофону запрещён. Разрешите в Системных настройках → Конфиденциальность → Микрофон.")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.statusDanger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SottoTokens.Spacing.m)
        } else if env.micTestRunning {
            VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
                LevelBar(level: env.micRMS)
                Text(String(
                    format: "кадров: %d · речь: %.0f%% · сброшено: %d",
                    env.micChunkCount, env.micSpeechRatio * 100, env.micDroppedBlocks
                ))
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
            }
            .padding(.horizontal, SottoTokens.Spacing.m)
        }
    }

    private func evalRow(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xxs) {
            HStack(spacing: SottoTokens.Spacing.s) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(SottoTokens.Color.sourceScreen)
                Text("Оценка расшифровки")
                    .font(SottoTokens.Font.captionMed)
                    .foregroundStyle(SottoTokens.Color.textSecondary)
                Spacer()
                if let folder = env.lastDebugFolder {
                    Button("отчёт") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .buttonStyle(.plain)
                        .font(SottoTokens.Font.caption)
                        .foregroundStyle(SottoTokens.Color.accent)
                }
            }
            Text(summary)
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SottoTokens.Spacing.m)
        .background(RoundedRectangle(cornerRadius: SottoTokens.Radius.sm).fill(SottoTokens.Color.surfaceRaised))
    }

    // MARK: - Хелперы

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SottoTokens.Font.caption)
            .foregroundStyle(SottoTokens.Color.textTertiary)
            .padding(.horizontal, SottoTokens.Spacing.m)
    }

    private var divider: some View {
        Divider().overlay(SottoTokens.Color.borderDefault)
    }

    /// Цвет статус-дота по состоянию — те же токены, что в оверлее (визуальная связность).
    private var stateColor: Color {
        switch env.conversation.sessionState {
        case .idle:      return SottoTokens.Color.sourceSystem
        case .warmingUp: return SottoTokens.Color.statusWarning
        case .listening: return SottoTokens.Color.statusSuccess
        case .thinking:  return SottoTokens.Color.sourceScreen
        case .failed:    return SottoTokens.Color.statusDanger
        }
    }
}

// MARK: - Переиспользуемые строки меню

/// Содержимое строки: иконка фикс-ширины + заголовок + опциональный trailing-шорткат.
/// Фон/тап навешивают обёртки (`MenuRow` / `SettingsRow`), чтобы вид был общим.
private struct MenuRowLabel: View {
    let icon: String
    let title: String
    var tint: Color = SottoTokens.Color.textSecondary

    var body: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(SottoTokens.Font.body)
                .foregroundStyle(SottoTokens.Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: SottoTokens.Spacing.s)
        }
        .padding(.horizontal, SottoTokens.Spacing.m)
        .padding(.vertical, SottoTokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Обычная строка-кнопка с hover-подсветкой.
private struct MenuRow: View {
    let icon: String
    let title: String
    var tint: Color = SottoTokens.Color.textSecondary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            MenuRowLabel(icon: icon, title: title, tint: tint)
                .background(
                    RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                        .fill(hover ? SottoTokens.Color.surfaceRaised : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Primary-строка: акцентная заливка (старт сессии / стоп).
private struct PrimaryRow: View {
    let icon: String
    let title: String
    var tint: Color = SottoTokens.Color.accent
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SottoTokens.Spacing.s) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(SottoTokens.Font.bodyMed)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SottoTokens.Color.textOnAccent)
            .padding(.horizontal, SottoTokens.Spacing.l)
            .padding(.vertical, SottoTokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.md)
                    .fill(tint.opacity(hover ? 0.85 : 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Строка «Настройки моделей» поверх системного `SettingsLink` (открывает сцену Settings),
/// со стилем строки меню и hover-подсветкой.
private struct SettingsRow: View {
    @State private var hover = false

    var body: some View {
        SettingsLink {
            MenuRowLabel(icon: "slider.horizontal.3", title: "Настройки моделей…")
                .background(
                    RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                        .fill(hover ? SottoTokens.Color.surfaceRaised : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Индикатор уровня сигнала (RMS) для теста микрофона — на токенах (голос=зелёный).
private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SottoTokens.Color.surfaceRaised)
                Capsule()
                    .fill(SottoTokens.Color.sourceVoice)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level * 6))))
            }
        }
        .frame(height: 6)
    }
}
