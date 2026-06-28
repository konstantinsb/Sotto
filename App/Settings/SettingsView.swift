import SwiftUI
import AppKit
import SottoCore

/// Настройки: выбор моделей и режима точности (смена модели — в приложении, не в коде).
/// Дизайн-система Sotto (Dark-first): приватностный фрейминг (локально·приватно /
/// облако·не приватно), единые баннеры `SottoBanner`, унифицированные инпуты,
/// явный футер применения. Функциональность 1:1 с прежним `Form`.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var modelsSize: Int64 = 0
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SottoTokens.Spacing.xl) {
                    modeSection
                    localSection
                    cloudSection
                    overlaySection
                    storageSection
                    debugSection
                }
                .padding(SottoTokens.Spacing.xl)
            }
            footer
        }
        .frame(width: 480, height: 560)
        .background(SottoTokens.Color.surfaceSolid)
        .foregroundStyle(SottoTokens.Color.textPrimary)
        .tint(SottoTokens.Color.accent)
        .preferredColorScheme(.dark)
        .task { await refreshModelsSize() }
        .confirmationDialog("Удалить все скачанные модели?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                ModelManager.deleteAllModels()
                Task { await refreshModelsSize() }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Секции

    private var modeSection: some View {
        section("Режим", icon: "slider.horizontal.3") {
            pickerRow("Режим", selection: modeBinding) {
                ForEach(ModeKind.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            privacyHeader("Модели", icon: "cpu", tag: "локально · приватно", color: SottoTokens.Color.statusSuccess)
            VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
                pickerRow("Распознавание (ASR)", selection: asrBinding) {
                    ForEach(env.registry.asr) { model in
                        Text(label(model)).tag(model.id)
                    }
                }
                pickerRow("Генерация (LLM)", selection: llmBinding) {
                    ForEach(env.registry.llm) { model in
                        Text(label(model)).tag(model.id)
                    }
                }
                Divider().overlay(SottoTokens.Color.borderDefault)
                infoRow("Устройство", "\(env.device.chipName) · \(Int(env.device.totalRAMGB.rounded())) ГБ")
                if let llm = selectedLLM, Double(llm.minRAMGB) > env.device.totalRAMGB {
                    SottoBanner(kind: .warning, text: "Выбранной LLM рекомендуется ≥\(llm.minRAMGB) ГБ — на этой машине рядом с Whisper возможны подвисания/нехватка памяти.")
                }
                note("Работает офлайн: аудио и расшифровка не покидают этот Mac.")
            }
            .sottoCard()
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            privacyHeader("Облако · режим точности", icon: "cloud", tag: "не приватно", color: SottoTokens.Color.statusWarning)
            VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
                Toggle("Использовать облако", isOn: cloudEnabledBinding)
                    .font(SottoTokens.Font.body)
                if env.cloudEnabled {
                    Divider().overlay(SottoTokens.Color.borderDefault)
                    pickerRow("Провайдер", selection: cloudProviderBinding) {
                        ForEach(CloudProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    switch env.cloudProvider {
                    case .anthropic:
                        pickerRow("Модель", selection: cloudModelBinding) {
                            ForEach(CloudModelOption.allCases) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                    case .openAI:
                        labeledField("Модель") {
                            TextField("напр. gpt-4o", text: cloudModelBinding).sottoField()
                        }
                    }
                    labeledField("API-ключ") {
                        SecureField("ключ провайдера", text: apiKeyBinding).sottoField()
                    }
                    if env.cloudAPIKey.isEmpty {
                        SottoBanner(kind: .warning, text: "Без ключа используется локальная модель.")
                    }
                    note(env.cloudProvider.keyHint)
                }
                note("Облако точнее на искажённых ASR-терминах (senior-ответы), но отправляет вопрос и контекст внешнему провайдеру. Из РФ нужен VPN. Применяется со следующего старта сессии.")
            }
            .sottoCard()
        }
    }

    private var overlaySection: some View {
        section("Оверлей", icon: "macwindow") {
            Toggle("Поверх всех окон (включая фуллскрин)", isOn: overlayAlwaysOnTopBinding)
                .font(SottoTokens.Font.body)
            note("Выкл (по умолчанию): панель над обычными окнами, но не поверх фуллскрина — меньше мешает вне звонка. Вкл: над всем, включая фуллскрин-шаринг звонка. Панель появляется на старте сессии; закрыть — × в баре или ⌥⌘\\.")
        }
    }

    private var storageSection: some View {
        section("Хранилище моделей", icon: "internaldrive") {
            infoRow("На диске", ModelManager.formatBytes(modelsSize))
            Button("Удалить все скачанные модели") { confirmDelete = true }
                .buttonStyle(SottoSecondaryButtonStyle(tint: SottoTokens.Color.statusDanger))
            note("Модели лежат в ~/Library/Application Support/Sotto и кэше HuggingFace. Удаление освободит место; при следующем старте они скачаются заново.")
        }
    }

    private var debugSection: some View {
        section("Отладка расшифровки", icon: "ladybug") {
            Toggle("Запись + авто-оценка качества расшифровки", isOn: debugBinding)
                .font(SottoTokens.Font.body)
            Button("Открыть папку записей") {
                NSWorkspace.shared.activateFileViewerSelecting([ModelManager.debugDirectory])
            }
            .buttonStyle(SottoSecondaryButtonStyle())
            note("Пишет аудио (system.wav) и transcript.jsonl, а после каждой сессии АВТОМАТИЧЕСКИ перетранскрибирует запись эталоном (целый файл) и сравнивает с живой расшифровкой → evaluation.txt (точность, WER). Папка: ~/Library/Application Support/Sotto/Debug.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(SottoTokens.Color.borderDefault)
            HStack(alignment: .top, spacing: SottoTokens.Spacing.s) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(SottoTokens.Color.textTertiary)
                Text("Изменения применяются при следующем старте сессии. Первый запуск выбранной модели скачивает веса.")
                    .font(SottoTokens.Font.caption)
                    .foregroundStyle(SottoTokens.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SottoTokens.Spacing.l)
        }
    }

    // MARK: - Переиспользуемые строки

    /// Секция с капс-заголовком (иконка) и карточкой-контейнером.
    @ViewBuilder
    private func section<Content: View>(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            SottoSectionHeader(title, icon: icon)
            VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) { content() }
                .sottoCard()
        }
    }

    /// Заголовок секции с пилюлей-индикатором приватности справа.
    private func privacyHeader(_ title: String, icon: String, tag: String, color: Color) -> some View {
        HStack(spacing: SottoTokens.Spacing.s) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(SottoTokens.Color.textTertiary)
            Text(title.uppercased())
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
            Spacer()
            HStack(spacing: SottoTokens.Spacing.xs) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(tag).font(SottoTokens.Font.caption).foregroundStyle(color)
            }
        }
    }

    /// Строка «лейбл слева — компактный picker справа».
    @ViewBuilder
    private func pickerRow<Value: Hashable, Content: View>(
        _ label: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label).font(SottoTokens.Font.body).foregroundStyle(SottoTokens.Color.textSecondary)
            Spacer(minLength: SottoTokens.Spacing.l)
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
    }

    /// Строка «лейбл слева — значение справа».
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(SottoTokens.Font.body).foregroundStyle(SottoTokens.Color.textSecondary)
            Spacer()
            Text(value).font(SottoTokens.Font.bodyMed).foregroundStyle(SottoTokens.Color.textPrimary)
        }
    }

    /// Полноширинное поле с мелким лейблом сверху.
    @ViewBuilder
    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.xs) {
            Text(label).font(SottoTokens.Font.caption).foregroundStyle(SottoTokens.Color.textTertiary)
            field()
        }
    }

    /// Пояснительная подпись (caption, третичный текст).
    private func note(_ text: String) -> some View {
        Text(text)
            .font(SottoTokens.Font.caption)
            .foregroundStyle(SottoTokens.Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Данные

    private func refreshModelsSize() async {
        modelsSize = await Task.detached { ModelManager.totalSizeBytes() }.value
    }

    private func label(_ model: ModelInfo) -> String {
        let base = String(format: "%@ · ~%.1f ГБ", model.displayName, model.approxSizeGB)
        // ⚠️ — единственный сканируемый маркер перебора RAM в .menu-пикере (отдельные пункты
        // dropdown стилизовать нельзя). Активную модель прикрывает баннер, прочие в списке — только это.
        return exceedsRAM(model) ? "⚠️ \(base) · нужно ≥\(model.minRAMGB) ГБ" : base
    }

    private func exceedsRAM(_ model: ModelInfo) -> Bool {
        Double(model.minRAMGB) > env.device.totalRAMGB
    }

    private var selectedLLM: ModelInfo? {
        env.registry.info(id: env.selection.llmModelID, kind: .llm)
    }

    // MARK: - Bindings

    private var modeBinding: Binding<ModeKind> {
        Binding(get: { env.selectedMode }, set: { env.updateMode($0) })
    }

    private var debugBinding: Binding<Bool> {
        Binding(get: { env.debugCaptureEnabled }, set: { env.setDebugCapture($0) })
    }

    private var overlayAlwaysOnTopBinding: Binding<Bool> {
        Binding(get: { env.overlayAlwaysOnTop }, set: { env.setOverlayAlwaysOnTop($0) })
    }

    private var cloudEnabledBinding: Binding<Bool> {
        Binding(get: { env.cloudEnabled }, set: { env.setCloudEnabled($0) })
    }

    private var cloudProviderBinding: Binding<CloudProvider> {
        Binding(get: { env.cloudProvider }, set: { env.setCloudProvider($0) })
    }

    private var cloudModelBinding: Binding<String> {
        Binding(get: { env.cloudModel }, set: { env.setCloudModel($0) })
    }

    private var apiKeyBinding: Binding<String> {
        Binding(get: { env.cloudAPIKey }, set: { env.setCloudAPIKey($0) })
    }

    private var asrBinding: Binding<String> {
        Binding(
            get: { env.selection.asrModelID },
            set: { env.updateSelection(ModelSelection(asrModelID: $0, llmModelID: env.selection.llmModelID)) }
        )
    }

    private var llmBinding: Binding<String> {
        Binding(
            get: { env.selection.llmModelID },
            set: { env.updateSelection(ModelSelection(asrModelID: env.selection.asrModelID, llmModelID: $0)) }
        )
    }
}
