import SwiftUI
import SottoCore

/// Содержимое плавающего окна в новой дизайн-системе: тонкий control bar (всегда) +
/// insight-карта, которая раскрывается, когда есть что показать.
///
/// View — только чтение из `AppEnvironment` (verified-аксессоры). Чисто-UI-состояние
/// (сворачивание карты, визуальный стелс-дим, непрозрачный фон, визуальный тогл микрофона)
/// живёт в локальных `@State` — за ним пока НЕТ модели данных (см. notes о заглушках).
///
/// Стелс по-честному: окно держит `sharingType = .none` + уровень assistive-tech на стороне
/// `FloatingPanel`. Тут только ВИЗУАЛЬНЫЙ дим/непрозрачный фон — ScreenCaptureKit окно
/// всё равно может видеть.
struct SuggestionOverlayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Анимация пульса статус-дота.
    @State private var pulse = false

    /// Демо-вторичные-подсказки без backing-данных. На живом собеседовании показывать
    /// выдуманное опасно, поэтому прячем. Q-чип и таймер сессии теперь читают реальные данные
    /// (conversation.lastQuestion / env.sessionStartedAt) и за флагом больше не сидят — убрать
    /// флаг целиком, когда появится модель вторичных подсказок.
    private let showDemoContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            controlBar

            if let error = env.conversation.lastError {
                errorRow(error)
            }
            if let progress = env.downloadProgress {
                downloadRow(progress)
            }

            insightCard

            // Автономная карта разбора — ТОЛЬКО без активной сессии. В сессии ответ
            // «код + устный вопрос» идёт через голосовой тракт в insightCard выше,
            // поэтому отдельную карту не дублируем.
            if !env.isRunning && env.screenAssist.phase != .idle {
                Divider().overlay(SottoTokens.Color.borderDefault)
                screenAssistArea
            }
        }
        .padding(SottoTokens.Spacing.l)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: SottoTokens.Radius.lg)
                .strokeBorder(SottoTokens.Color.borderGlassEdge, lineWidth: 1)
        )
        .sottoGlassShadow()
        .foregroundStyle(SottoTokens.Color.textPrimary)
        .onAppear { startPulse() }
    }

    // MARK: - Фон карты

    private var cardBackground: some View {
        // Стекло: системный материал + тонировка surface/glass. ZStack — явный порядок слоёв
        // (тонировка поверх материала), не зависящий от TupleView.
        ZStack {
            RoundedRectangle(cornerRadius: SottoTokens.Radius.lg).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: SottoTokens.Radius.lg).fill(SottoTokens.Color.surfaceGlass)
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            // Захват для перетаскивания (окно двигается через isMovableByWindowBackground).
            Image(systemName: "line.3.horizontal")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)

            statusDot
            Text(stateTitle)
                .font(SottoTokens.Font.bodyMed)
                .foregroundStyle(SottoTokens.Color.textPrimary)
                .lineLimit(1)

            // Таймер сессии: тикает, пока сессия активна (env.sessionStartedAt + TimelineView).
            if env.isRunning { timerBadge }

            Spacer(minLength: SottoTokens.Spacing.s)

            latencyBadge

            screenAssistButton

            // Закрыть панель (orderOut, без уничтожения). Вернуть — глобальным ⌥⌘\ или из меню.
            iconToggle(
                systemName: "xmark",
                tint: SottoTokens.Color.textTertiary,
                isOn: false,
                help: "Закрыть (вернуть — ⌥⌘\\)"
            ) { env.hideOverlay() }
        }
    }

    /// Статус-дот с пульсом. Пульс — только на активных состояниях (слушаю/думаю/прогрев),
    /// уважает Reduce Motion.
    private var statusDot: some View {
        ZStack {
            if showPulse && !reduceMotion {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.6)
            }
            Circle().fill(stateColor).frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
    }

    /// Таймер сессии: прошедшее время от env.sessionStartedAt, обновляется раз в секунду.
    /// TimelineView тикает сам; sessionStartedAt @ObservationIgnored, но к моменту перерисовки
    /// (по наблюдаемому env.isRunning) уже выставлен на старте сессии.
    private var timerBadge: some View {
        TimelineView(.periodic(from: env.sessionStartedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(env.sessionStartedAt))
            HStack(spacing: SottoTokens.Spacing.xxs) {
                Image(systemName: "clock").font(.system(size: 9))
                Text(elapsedText(elapsed)).font(SottoTokens.Font.monoMed)
            }
            .foregroundStyle(SottoTokens.Color.textTertiary)
        }
    }

    /// mm:ss, а после часа — h:mm:ss. Моноширинно (monoMed), чтобы цифры не «прыгали».
    private func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// Бейдж задержки: цвет по значению (real `lastLatencyMs`) + инициалы модели из последней
    /// подсказки (real `suggestions.first?.model`), если есть. Скрыт, пока задержки нет.
    @ViewBuilder
    private var latencyBadge: some View {
        if let ms = env.conversation.lastLatencyMs {
            HStack(spacing: SottoTokens.Spacing.xxs) {
                Image(systemName: "bolt.fill").font(.system(size: 9))
                Text(latencyText(ms)).font(SottoTokens.Font.monoMed)
                if let initials = modelInitials {
                    Text("· \(initials)").font(SottoTokens.Font.monoMed)
                }
            }
            .padding(.horizontal, SottoTokens.Spacing.s)
            .padding(.vertical, SottoTokens.Spacing.xxs)
            .foregroundStyle(latencyColor(ms))
            .background(
                Capsule().fill(latencyColor(ms).opacity(0.16))
            )
        }
    }

    /// Разбор экрана (OCR + LLM) — живёт в оверлее (раньше был пункт меню). Глобальный хоткей
    /// ⌥⌘S тоже работает; локальный шорткат не вешаем, чтобы не словить двойной вызов.
    private var screenAssistButton: some View {
        // «Идёт разбор» — автономный (screenAssist.isRunning), захват экрана для голосового
        // тракта (screenAnalyzing) ИЛИ уже идущая голосовая генерация в активной сессии
        // (.thinking): захват короткий, а генерация после него длится дольше, и кнопка должна
        // оставаться занятой всё это время (иначе повторный ⌥⌘S запустил бы второй разбор
        // поверх идущего). Подсвечиваем и блокируем кнопку.
        let busy = env.screenAssist.isRunning
            || env.screenAnalyzing
            || (env.isRunning && env.conversation.sessionState == .thinking)
        return Button(action: { env.analyzeScreen() }) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(busy
                                 ? SottoTokens.Color.sourceScreen
                                 : SottoTokens.Color.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                        .fill(busy ? SottoTokens.Color.accentMuted : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Разобрать экран (⌥⌘S)")
    }

    // MARK: - Insight card

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.l) {
            questionChip
            leadLine
            bodyLine
            secondarySuggestions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: env.conversation.lastQuestion)
    }

    /// Чип «Q: <вопрос>» — реальный распознанный вопрос (conversation.lastQuestion, наполняется
    /// из .questionDetected). `.id(question)` + `.transition` дают фейд-свежесть при смене вопроса
    /// (анимация — на insightCard, value: lastQuestion).
    @ViewBuilder
    private var questionChip: some View {
        if let question = env.conversation.lastQuestion, !question.isEmpty {
            HStack(spacing: SottoTokens.Spacing.s) {
                Image(systemName: "questionmark.circle").font(SottoTokens.Font.caption)
                Text(question)
                    .font(SottoTokens.Font.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(SottoTokens.Color.accent)
            .padding(.horizontal, SottoTokens.Spacing.m)
            .padding(.vertical, SottoTokens.Spacing.xs)
            .background(Capsule().fill(SottoTokens.Color.accentMuted))
            .id(question)
            .transition(.opacity)
        }
    }

    /// Lead — крупная потоковая подсказка (currentSuggestion). Текст растёт по токенам как есть:
    /// отдельный typewriter поверх уже-потокового стрима дублировал бы анимацию и рисковал
    /// отставать от реальных токенов — осознанно не добавляем (см. чат-лог, доводка оверлея).
    private var leadLine: some View {
        ScrollView {
            Text(env.conversation.currentSuggestion.isEmpty ? "Подсказка появится здесь…" : env.conversation.currentSuggestion)
                .font(SottoTokens.Font.lead)
                .foregroundStyle(env.conversation.currentSuggestion.isEmpty
                                 ? SottoTokens.Color.textTertiary
                                 : SottoTokens.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Body — живой транскрипт под подсказкой: finals (source-coded цветом/иконкой) +
    /// живые partial'ы обоих источников с хвостом «…». Источник из AudioSource:
    /// .microphone → голос (зелёный, свой голос), .system → экран (небо, собеседник).
    @ViewBuilder
    private var bodyLine: some View {
        let systemPartial = env.conversation.partials[.system]
        let micPartial = env.conversation.partials[.microphone]
        if !env.conversation.finals.isEmpty
            || systemPartial?.isEmpty == false
            || micPartial?.isEmpty == false {
            // ScrollView по умолчанию якорится сверху и не следует за новым контентом —
            // живой partial (особенно свой голос, он внизу) уезжал бы за нижнюю кромку.
            // Держим прокрутку у низа: на каждый прирост текста скроллим к якорю.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
                        ForEach(env.conversation.finals) { segment in
                            transcriptLine(source: segment.source, text: segment.text, isPartial: false)
                        }
                        if let systemPartial, !systemPartial.isEmpty {
                            transcriptLine(source: .system, text: systemPartial + "…", isPartial: true)
                        }
                        if let micPartial, !micPartial.isEmpty {
                            transcriptLine(source: .microphone, text: micPartial + "…", isPartial: true)
                        }
                        Color.clear.frame(height: 1).id(transcriptBottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .onChange(of: transcriptTick) { _, _ in
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
                .onAppear { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
            }
        }
    }

    /// Стабильный якорь низа живого транскрипта (для авто-скролла к свежему тексту).
    private let transcriptBottomID = "transcriptBottom"

    /// Меняется при любом приросте транскрипта (новый финал или рост partial'а) — триггер
    /// авто-скролла к низу: число финалов + длины partial'ов обоих источников.
    private var transcriptTick: Int {
        env.conversation.finals.count
            + (env.conversation.partials[.system]?.count ?? 0)
            + (env.conversation.partials[.microphone]?.count ?? 0)
    }

    private func transcriptLine(source: AudioSource, text: String, isPartial: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SottoTokens.Spacing.s) {
            Image(systemName: sourceSymbol(source))
                .font(.system(size: 10))
                .foregroundStyle(sourceColor(source))
            Text(text)
                .font(SottoTokens.Font.body)
                .foregroundStyle(isPartial ? SottoTokens.Color.textTertiary : SottoTokens.Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Вторичные подсказки по источникам (экран/AI) — ЗАГЛУШКА-демонстрация: на conversation
    /// нет структуры вторичных подсказок. Прячем за showDemoContent, чтобы не показывать
    /// выдуманное вживую. Заменить на реальные данные позже.
    @ViewBuilder
    private var secondarySuggestions: some View {
        if showDemoContent && hasAnswerFlow {
            VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
                secondaryCard(
                    source: .system,
                    tag: "С экрана",
                    text: "Свяжите ответ с тем, что открыто на экране собеседника."
                )
                secondaryCard(
                    source: nil,
                    tag: "AI · структура",
                    text: "Держите баланс «я» и «мы»: вклад — конкретикой, роль команды — одной фразой."
                )
            }
        }
    }

    /// source == .system → экран (небо); source == nil → AI (индиго); .microphone → голос (зелёный).
    private func secondaryCard(source: AudioSource?, tag: String, text: String) -> some View {
        let tint = source.map(sourceColor) ?? SottoTokens.Color.sourceAI
        let symbol = source.map(sourceSymbol) ?? "sparkles"
        return HStack(alignment: .top, spacing: SottoTokens.Spacing.m) {
            RoundedRectangle(cornerRadius: SottoTokens.Radius.full).fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: SottoTokens.Spacing.xxs) {
                HStack(spacing: SottoTokens.Spacing.xs) {
                    Image(systemName: symbol).font(.system(size: 10))
                    Text(tag).font(SottoTokens.Font.captionMed)
                }
                .foregroundStyle(tint)
                Text(text)
                    .font(SottoTokens.Font.body)
                    .foregroundStyle(SottoTokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SottoTokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: SottoTokens.Radius.md).fill(SottoTokens.Color.surfaceRaised)
        )
    }

    // MARK: - Разбор экрана

    private var screenAssistArea: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.s) {
            HStack(spacing: SottoTokens.Spacing.s) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .foregroundStyle(SottoTokens.Color.sourceScreen)
                Text("Разбор экрана")
                    .font(SottoTokens.Font.bodyMed)
                    .foregroundStyle(SottoTokens.Color.textPrimary)
                Spacer()
                if env.screenAssist.isRunning {
                    Text(env.screenAssist.phase == .capturing ? "распознаю…" : "думаю…")
                        .font(SottoTokens.Font.caption)
                        .foregroundStyle(SottoTokens.Color.textTertiary)
                }
            }
            if let error = env.screenAssist.lastError {
                Text(error)
                    .font(SottoTokens.Font.caption)
                    .foregroundStyle(SottoTokens.Color.statusDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(screenAssistText)
                    .font(SottoTokens.Font.mono)
                    .foregroundStyle(env.screenAssist.solution.isEmpty
                                     ? SottoTokens.Color.textTertiary
                                     : SottoTokens.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    private var screenAssistText: String {
        if !env.screenAssist.solution.isEmpty { return env.screenAssist.solution }
        switch env.screenAssist.phase {
        case .capturing: return "Распознаю экран…"
        case .thinking: return "Готовлю решение…"
        default: return "—"
        }
    }

    // MARK: - Строки ошибки и загрузки

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: SottoTokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.statusDanger)
            Text(message)
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.statusDanger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func downloadRow(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
            HStack(spacing: SottoTokens.Spacing.m) {
                ProgressView().controlSize(.small)   // всегда крутится — видно, что загрузка жива
                // Определённый бар — только при реальном росте (Parakeet/FluidAudio не отдаёт
                // инкрементальный прогресс, fraction == 0 всю загрузку).
                if progress.fraction > 0 {
                    ProgressView(value: progress.fraction)
                        .tint(SottoTokens.Color.accent)
                }
            }
            Text(downloadCaption(progress))
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func downloadCaption(_ progress: DownloadProgress) -> String {
        var line = env.downloadLabel
        if progress.fraction > 0 { line += " — \(progress.percent)%" }
        if let size = progress.sizeText { line += " · \(size)" }
        let tail = progress.percent >= 100
            ? "Готовлю модель — почти всё."
            : (progress.fraction > 0
               ? "Первая загрузка — несколько ГБ. Идёт скачивание, не закрывай."
               : "Загрузка модели… (может занять пару минут), не закрывай.")
        return line + "\n" + tail
    }

    // MARK: - Переиспользуемый тогл-кнопка

    private func iconToggle(
        systemName: String,
        tint: Color,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                        .fill(isOn ? SottoTokens.Color.accentMuted : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Хелперы состояния

    /// Идёт ли поток ответа (используем как косвенный признак «есть вопрос/ответ»),
    /// раз отдельного состояния «подсказка готова» в модели нет.
    private var hasAnswerFlow: Bool {
        !env.conversation.currentSuggestion.isEmpty
            || env.conversation.lastLatencyMs != nil
            || env.conversation.sessionState == .thinking
    }

    /// Пульсируем только на активных состояниях.
    private var showPulse: Bool {
        switch env.conversation.sessionState {
        case .listening, .thinking, .warmingUp: return true
        case .idle, .failed: return false
        }
    }

    /// Заголовок состояния. Когда ответ готов (есть задержка, сессия уже не «думает») —
    /// показываем «Готово»; иначе системный title состояния.
    private var stateTitle: String {
        if env.conversation.lastLatencyMs != nil
            && env.conversation.sessionState == .listening
            && !env.conversation.currentSuggestion.isEmpty {
            return "Готово"
        }
        return env.conversation.sessionState.title
    }

    /// Инициалы модели из последней подсказки (suggestions.first?.model — verified-аксессор).
    private var modelInitials: String? {
        guard let model = env.conversation.suggestions.first?.model, !model.isEmpty else { return nil }
        // Берём первое «слово» названия модели (Qwen3-… → Qwen3), обрезаем до ~6 символов.
        let head = model.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" }).first.map(String.init) ?? model
        return String(head.prefix(6))
    }

    private func latencyText(_ ms: Int) -> String {
        ms >= 1000 ? String(format: "%.2f с", Double(ms) / 1000) : "\(ms) мс"
    }

    /// Цвет задержки по значению: <800 мс — успех, <2000 — предупреждение, иначе — опасность.
    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<800:  return SottoTokens.Color.statusSuccess
        case ..<2000: return SottoTokens.Color.statusWarning
        default:      return SottoTokens.Color.statusDanger
        }
    }

    private func sourceColor(_ source: AudioSource) -> Color {
        // AudioSource имеет только .microphone/.system — голос=зелёный, экран(система)=небо.
        source == .system ? SottoTokens.Color.sourceScreen : SottoTokens.Color.sourceVoice
    }

    private func sourceSymbol(_ source: AudioSource) -> String {
        source == .system ? "display" : "waveform"
    }

    private var stateColor: Color {
        // Токены вместо raw SwiftUI-цветов: warmingUp=status/warning, thinking=source/screen и т.д.
        switch env.conversation.sessionState {
        case .idle:      return SottoTokens.Color.sourceSystem
        case .warmingUp: return SottoTokens.Color.statusWarning
        case .listening: return SottoTokens.Color.statusSuccess
        case .thinking:  return SottoTokens.Color.sourceScreen
        case .failed:    return SottoTokens.Color.statusDanger
        }
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
