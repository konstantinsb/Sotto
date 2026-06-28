import SwiftUI

/// Дизайн-система Sotto (Dark-first). Единое пространство имён токенов из Figma:
/// цвет, типографика, отступы, радиусы и стеклянная тень оверлея.
///
/// Значения — ровно из Figma (см. бриф редизайна). Используем `Color(.sRGB, …)` с альфой,
/// чтобы цвета совпадали с макетом независимо от системной палитры. Файл не зависит от
/// `AppEnvironment` и не привязан к актёру: `Color`/`Font` безопасны в любом контексте.
enum SottoTokens {

    // MARK: - Цвет (Dark)

    /// Палитра из Figma. Группы повторяют токены макета: surface/border/text/accent/source/status.
    enum Color {
        // Поверхности
        /// surface/glass — основной фон стеклянной карты (поверх .ultraThinMaterial).
        static let surfaceGlass  = SwiftUI.Color(.sRGB, red: 15/255, green: 23/255, blue: 42/255, opacity: 0.72)
        /// surface/solid — непрозрачный фон для светлой демонстрации экрана.
        static let surfaceSolid  = SwiftUI.Color(.sRGB, red:  2/255, green:  6/255, blue: 23/255, opacity: 1)
        /// surface/raised — приподнятые элементы (чипы, поле ввода).
        static let surfaceRaised = SwiftUI.Color(.sRGB, red: 255/255, green: 255/255, blue: 255/255, opacity: 0.06)

        // Границы
        /// border/glass-edge — светлая кромка стекла.
        static let borderGlassEdge = SwiftUI.Color(.sRGB, red: 255/255, green: 255/255, blue: 255/255, opacity: 0.14)
        /// border/default — обычная разделительная линия.
        static let borderDefault   = SwiftUI.Color(.sRGB, red: 255/255, green: 255/255, blue: 255/255, opacity: 0.08)

        // Текст
        static let textPrimary   = SwiftUI.Color(.sRGB, red: 248/255, green: 250/255, blue: 252/255, opacity: 1) // #F8FAFC
        static let textSecondary = SwiftUI.Color(.sRGB, red: 203/255, green: 213/255, blue: 225/255, opacity: 1) // #CBD5E1
        static let textTertiary  = SwiftUI.Color(.sRGB, red: 148/255, green: 163/255, blue: 184/255, opacity: 1) // #94A3B8
        static let textOnAccent  = SwiftUI.Color(.sRGB, red: 255/255, green: 255/255, blue: 255/255, opacity: 1) // #FFFFFF

        // Акцент
        static let accent      = SwiftUI.Color(.sRGB, red: 129/255, green: 140/255, blue: 248/255, opacity: 1)    // #818CF8
        static let accentMuted = SwiftUI.Color(.sRGB, red: 129/255, green: 140/255, blue: 248/255, opacity: 0.16)

        // Источники (цветовое кодирование подсказок/транскрипта)
        static let sourceVoice  = SwiftUI.Color(.sRGB, red:  52/255, green: 211/255, blue: 153/255, opacity: 1)   // #34D399 mic
        static let sourceScreen = SwiftUI.Color(.sRGB, red:  56/255, green: 189/255, blue: 248/255, opacity: 1)   // #38BDF8 screen
        static let sourceAI     = SwiftUI.Color(.sRGB, red: 129/255, green: 140/255, blue: 248/255, opacity: 1)   // #818CF8 ai
        static let sourceSystem = SwiftUI.Color(.sRGB, red: 148/255, green: 163/255, blue: 184/255, opacity: 1)   // #94A3B8 gray

        // Статус
        static let statusSuccess = SwiftUI.Color(.sRGB, red:  74/255, green: 222/255, blue: 128/255, opacity: 1)  // #4ADE80
        static let statusWarning = SwiftUI.Color(.sRGB, red: 251/255, green: 191/255, blue:  36/255, opacity: 1)  // #FBBF24
        static let statusDanger  = SwiftUI.Color(.sRGB, red: 248/255, green: 113/255, blue: 113/255, opacity: 1)  // #F87171
    }

    // MARK: - Типографика

    /// Роли шрифта (SF Pro системный). Размеры из Figma: caption 11 / body 13 / lead 15 (semibold) /
    /// title 17 / mono 12. Фиксированные кегли — осознанный выбор под плотный оверлей; минимум 11pt.
    enum Font {
        static let caption     = SwiftUI.Font.system(size: 11, weight: .regular)
        static let captionMed  = SwiftUI.Font.system(size: 11, weight: .medium)
        static let body        = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodyMed     = SwiftUI.Font.system(size: 13, weight: .medium)
        /// lead — крупная фраза «что сказать».
        static let lead        = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let title       = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// mono — код/решение разбора экрана (JetBrains Mono в макете; в приложении — системный моно).
        static let mono        = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)
        /// monoMed — числовые бейджи (задержка, таймер) моноширинно, чтобы не «прыгали».
        static let monoMed     = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    // MARK: - Отступы

    /// Шкала отступов Figma: 2/4/6/8/12/16/24/32.
    enum Spacing {
        static let xxs:  CGFloat = 2
        static let xs:   CGFloat = 4
        static let s:    CGFloat = 6
        static let m:    CGFloat = 8
        static let l:    CGFloat = 12
        static let xl:   CGFloat = 16
        static let xxl:  CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Радиусы

    /// sm=8 · md=12 · lg=16 · full=999.
    enum Radius {
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let full: CGFloat = 999
    }

    // MARK: - Тень (стекло)

    /// Shadow/Glass из Figma: 0 12 32 rgba(0,0,0,.40) + 0 2 8 rgba(0,0,0,.24).
    /// Два слоя — глубокий мягкий и плотный ближний. Модификатор `.sottoGlassShadow()`.
    enum Elevation {
        static let glassFarColor  = SwiftUI.Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.40)
        static let glassFarRadius:  CGFloat = 16   // SwiftUI radius ≈ blur/2 (Figma blur 32)
        static let glassFarY:       CGFloat = 12
        static let glassNearColor = SwiftUI.Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.24)
        static let glassNearRadius: CGFloat = 4    // Figma blur 8
        static let glassNearY:      CGFloat = 2
    }
}

// MARK: - Модификаторы

extension View {
    /// Стеклянная тень оверлея (Shadow/Glass): два наложенных слоя.
    func sottoGlassShadow() -> some View {
        self
            .shadow(color: SottoTokens.Elevation.glassNearColor,
                    radius: SottoTokens.Elevation.glassNearRadius,
                    x: 0, y: SottoTokens.Elevation.glassNearY)
            .shadow(color: SottoTokens.Elevation.glassFarColor,
                    radius: SottoTokens.Elevation.glassFarRadius,
                    x: 0, y: SottoTokens.Elevation.glassFarY)
    }

    /// Унифицированный текстовый инпут: приподнятая поверхность + граница + радиус sm.
    /// Применяется к `TextField`/`SecureField` (со стилем `.plain`) — единый вид полей
    /// во всех окнах редизайна (Settings/Профиль).
    func sottoField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(SottoTokens.Font.body)
            .foregroundStyle(SottoTokens.Color.textPrimary)
            .padding(.horizontal, SottoTokens.Spacing.m)
            .padding(.vertical, SottoTokens.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                    .fill(SottoTokens.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.sm)
                    .strokeBorder(SottoTokens.Color.borderDefault, lineWidth: 1)
            )
    }

    /// Карточка-контейнер секции: приподнятая поверхность + тонкая граница + радиус md.
    /// Общий контейнер для окон редизайна (Settings/Профиль/История/Summary/Mock).
    func sottoCard(padding: CGFloat = SottoTokens.Spacing.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.md)
                    .fill(SottoTokens.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.md)
                    .strokeBorder(SottoTokens.Color.borderDefault, lineWidth: 1)
            )
    }
}

// MARK: - Переиспользуемые компоненты дизайн-системы (env-free)

/// Заголовок секции: мелкий капс-лейбл с опциональной иконкой.
struct SottoSectionHeader: View {
    let title: String
    var icon: String?
    init(_ title: String, icon: String? = nil) { self.title = title; self.icon = icon }
    var body: some View {
        HStack(spacing: SottoTokens.Spacing.s) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(SottoTokens.Color.textTertiary)
            }
            Text(title.uppercased())
                .font(SottoTokens.Font.caption)
                .foregroundStyle(SottoTokens.Color.textTertiary)
        }
    }
}

/// Краткий баннер-уведомление (предупреждение/инфо/опасность) на тонкой тинте.
struct SottoBanner: View {
    enum Kind {
        case warning, info, danger
        var color: Color {
            switch self {
            case .warning: return SottoTokens.Color.statusWarning
            case .info:    return SottoTokens.Color.accent
            case .danger:  return SottoTokens.Color.statusDanger
            }
        }
        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .info:    return "info.circle"
            case .danger:  return "xmark.octagon"
            }
        }
    }
    let kind: Kind
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: SottoTokens.Spacing.s) {
            Image(systemName: kind.symbol).font(.system(size: 11)).foregroundStyle(kind.color)
            Text(text)
                .font(SottoTokens.Font.caption)
                .foregroundStyle(kind.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SottoTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SottoTokens.Radius.sm).fill(kind.color.opacity(0.14)))
    }
}

/// Акцентная primary-кнопка (заливка indigo).
struct SottoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SottoTokens.Font.bodyMed)
            .foregroundStyle(SottoTokens.Color.textOnAccent)
            .padding(.horizontal, SottoTokens.Spacing.l)
            .padding(.vertical, SottoTokens.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.md)
                    .fill(SottoTokens.Color.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// Вторичная кнопка: приподнятая поверхность + граница; tint красит текст (напр. destructive).
struct SottoSecondaryButtonStyle: ButtonStyle {
    var tint: Color = SottoTokens.Color.textPrimary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SottoTokens.Font.bodyMed)
            .foregroundStyle(tint)
            .padding(.horizontal, SottoTokens.Spacing.l)
            .padding(.vertical, SottoTokens.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.md)
                    .fill(SottoTokens.Color.surfaceRaised.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SottoTokens.Radius.md)
                    .strokeBorder(SottoTokens.Color.borderDefault, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
