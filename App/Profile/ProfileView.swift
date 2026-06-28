import SwiftUI
import SottoCore

/// Редактор именованных профилей (контекстов). Активный профиль идёт в подсказки и разбор
/// экрана; текст профиля используется RAG'ом для персональных подсказок.
/// Дизайн-система Sotto (Dark-first): карточки-секции, унифицированные инпуты (`.sottoField()`/
/// токенизированный `TextEditor`), Sotto-кнопки, явный футер сохранения. Логика 1:1 с прежним `Form`.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draftName = ""
    @State private var draft = UserProfile()
    @State private var newProfileName = ""
    @State private var saved = false
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SottoTokens.Spacing.xl) {
                    header
                    profileSection
                    nameSection
                    editorSection("Опыт / о себе", icon: "person.text.rectangle", text: $draft.about, minHeight: 90)
                    editorSection("Проекты", icon: "folder", text: $draft.projects, minHeight: 70)
                    editorSection("Стек", icon: "cube", text: $draft.stack, minHeight: 50)
                    editorSection("STAR-истории", icon: "star", text: $draft.starStories, minHeight: 90)
                    note("Несколько профилей под разные сценарии (резюме, стек, тип задач). Активный профиль режется на чанки, считаются эмбеддинги, под вопрос достаются релевантные куски (RAG). Хранится локально (шифрованно). Применяется при следующем старте сессии.")
                }
                .padding(SottoTokens.Spacing.xl)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 620)
        .background(SottoTokens.Color.surfaceSolid)
        .foregroundStyle(SottoTokens.Color.textPrimary)
        .tint(SottoTokens.Color.accent)
        .preferredColorScheme(.dark)
        .onAppear { if !loaded { loadFromActive(); loaded = true } }
        .onChange(of: draft) { saved = false }
        .onChange(of: draftName) { saved = false }
    }

    // MARK: - Секции

    private var header: some View {
        HStack(spacing: SottoTokens.Spacing.m) {
            Image(systemName: "person.crop.rectangle")
                .foregroundStyle(SottoTokens.Color.accent)
            Text("Профиль · контекст").font(SottoTokens.Font.title)
            Spacer()
        }
    }

    private var profileSection: some View {
        section("Профиль (контекст)", icon: "person.2") {
            pickerRow("Активный", selection: activeBinding) {
                ForEach(env.library.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }
            HStack(spacing: SottoTokens.Spacing.m) {
                TextField("Имя нового профиля", text: $newProfileName).sottoField()
                Button("Добавить") {
                    env.addProfile(name: newProfileName.trimmingCharacters(in: .whitespaces))
                    newProfileName = ""
                    loadFromActive()
                }
                .buttonStyle(SottoSecondaryButtonStyle())
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if env.library.profiles.count > 1, let id = env.library.selectedID {
                Button("Удалить «\(draftName)»") {
                    env.removeProfile(id: id)
                    loadFromActive()
                }
                .buttonStyle(SottoSecondaryButtonStyle(tint: SottoTokens.Color.statusDanger))
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            SottoSectionHeader("Имя профиля", icon: "textformat")
            TextField("Имя", text: $draftName).sottoField()
        }
    }

    /// Поле-редактор большого текста: заголовок + токенизированный `TextEditor` (сам по себе —
    /// бордюр-контейнер, поэтому без обёртки в карточку, чтобы не было двойной рамки).
    private func editorSection(_ title: String, icon: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: SottoTokens.Spacing.m) {
            SottoSectionHeader(title, icon: icon)
            editor(text, minHeight: minHeight)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(SottoTokens.Color.borderDefault)
            HStack(spacing: SottoTokens.Spacing.m) {
                Button("Сохранить") { save() }
                    .buttonStyle(SottoPrimaryButtonStyle())
                if saved {
                    HStack(spacing: SottoTokens.Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Сохранено")
                    }
                    .font(SottoTokens.Font.caption)
                    .foregroundStyle(SottoTokens.Color.statusSuccess)
                }
                Spacer()
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

    /// Токенизированный многострочный редактор: прозрачный системный фон + приподнятая поверхность.
    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(SottoTokens.Font.body)
            .foregroundStyle(SottoTokens.Color.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(SottoTokens.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                    .fill(SottoTokens.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                    .strokeBorder(SottoTokens.Color.borderDefault, lineWidth: 1)
            )
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

    /// Биндинг активного профиля: смена в пикере переключает контекст и перезагружает черновик.
    private var activeBinding: Binding<UUID> {
        Binding(
            get: { env.library.selectedID ?? env.library.profiles.first?.id ?? UUID() },
            set: { id in
                env.selectProfile(id: id)
                loadFromActive()
            }
        )
    }

    /// Загрузить черновик из активного профиля.
    private func loadFromActive() {
        if let selected = env.library.selected {
            draft = selected.profile
            draftName = selected.name
        } else {
            draft = UserProfile()
            draftName = ""
        }
        saved = false
    }

    /// Сохранить имя и содержимое активного профиля.
    private func save() {
        guard let id = env.library.selectedID else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        env.renameProfile(id: id, to: name.isEmpty ? "Профиль" : name)
        env.updateProfileContent(id: id, profile: draft)
        saved = true
    }
}
