import Foundation
import SottoCore

/// Персистентность выбора моделей через `UserDefaults`.
/// (SwiftData-хранилище настроек придёт в фазе 9; для выбора модели достаточно этого.)
struct SettingsStore {
    private let key = "sotto.model.selection"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSelection() -> ModelSelection {
        loadSelection(default: .default)
    }

    /// Загрузить сохранённый выбор; если пользователь ещё ничего не выбирал — вернуть
    /// `fallback` (на первом запуске сюда передаём рекомендацию под устройство, A4).
    func loadSelection(default fallback: ModelSelection) -> ModelSelection {
        guard let data = defaults.data(forKey: key),
              let selection = try? JSONDecoder().decode(ModelSelection.self, from: data) else {
            return fallback
        }
        return selection
    }

    func saveSelection(_ selection: ModelSelection) {
        if let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: key)
        }
    }

    func loadMode() -> ModeKind {
        guard let raw = defaults.string(forKey: "sotto.mode"), let mode = ModeKind(rawValue: raw) else {
            return .iosInterview
        }
        return mode
    }

    func saveMode(_ mode: ModeKind) {
        defaults.set(mode.rawValue, forKey: "sotto.mode")
    }

    func loadDebugCapture() -> Bool {
        defaults.bool(forKey: "sotto.debugCapture")
    }

    func saveDebugCapture(_ enabled: Bool) {
        defaults.set(enabled, forKey: "sotto.debugCapture")
    }

    /// «Оверлей поверх всех окон». Дефолт (нет ключа) — false: вежливый .floating.
    func loadOverlayAlwaysOnTop() -> Bool {
        defaults.bool(forKey: "sotto.overlay.alwaysOnTop")
    }

    func saveOverlayAlwaysOnTop(_ enabled: Bool) {
        defaults.set(enabled, forKey: "sotto.overlay.alwaysOnTop")
    }

    // MARK: - Облако (режим точности): флаг + выбор модели.
    // Сам API-ключ — НЕ здесь, а в Keychain (см. `CloudCredentialStore`).

    func loadCloudEnabled() -> Bool {
        defaults.bool(forKey: "sotto.cloud.enabled")
    }

    func saveCloudEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "sotto.cloud.enabled")
    }

    func loadCloudModel() -> String {
        defaults.string(forKey: "sotto.cloud.model") ?? CloudProvider.default.defaultModel
    }

    func saveCloudModel(_ model: String) {
        defaults.set(model, forKey: "sotto.cloud.model")
    }

    func loadCloudProvider() -> CloudProvider {
        CloudProvider(rawValue: defaults.string(forKey: "sotto.cloud.provider") ?? "") ?? .default
    }

    func saveCloudProvider(_ provider: CloudProvider) {
        defaults.set(provider.rawValue, forKey: "sotto.cloud.provider")
    }
}

/// Облачный провайдер: нативный Anthropic (`/v1/messages`) или OpenAI-совместимый
/// (`/chat/completions` — OpenAI, прокси, OpenRouter). Ключи разных провайдеров хранятся
/// в Keychain раздельно (см. `keychainAccount`).
enum CloudProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI

    static let `default` = CloudProvider.anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI (ChatGPT)"
        }
    }

    /// Модель по умолчанию при выборе провайдера.
    var defaultModel: String {
        switch self {
        case .anthropic: return CloudModelOption.default.id   // claude-sonnet-4-6
        case .openAI: return "gpt-4o"
        }
    }

    /// Keychain-аккаунт ключа этого провайдера.
    var keychainAccount: String {
        switch self {
        case .anthropic: return "anthropic-api-key"
        case .openAI: return "openai-api-key"
        }
    }

    /// Где взять ключ — для подсказки в UI.
    var keyHint: String {
        switch self {
        case .anthropic:
            return "Ключ — на console.anthropic.com (оплата по токенам, отдельно от подписки claude.ai)."
        case .openAI:
            return "Ключ — на platform.openai.com (оплата по токенам, отдельно от подписки ChatGPT). Модель — чат-класса: gpt-4o, gpt-4.1 и т.п."
        }
    }
}

/// Доступные облачные модели Claude (нативный Anthropic API). Sonnet 4.6 — рекомендация
/// (senior-уровень, восстанавливает искажённые ASR-термины); Haiku 4.5 — бюджетный
/// вариант. Обе принимают `temperature` (в отличие от Opus 4.8/4.7).
enum CloudModelOption: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-4-6"
    case haiku = "claude-haiku-4-5"

    static let `default` = CloudModelOption.sonnet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sonnet: return "Claude Sonnet 4.6 · точнее (рекомендуется)"
        case .haiku: return "Claude Haiku 4.5 · дешевле/быстрее"
        }
    }
}
