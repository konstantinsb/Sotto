import Foundation

/// Именованный профиль: контекст под конкретный сценарий («Резюме iOS», «Стек», «Задачи»).
public struct NamedProfile: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var profile: UserProfile

    public init(id: UUID = UUID(), name: String, profile: UserProfile = UserProfile()) {
        self.id = id
        self.name = name
        self.profile = profile
    }
}

/// Библиотека профилей с одним активным. Пользователь держит несколько контекстов и
/// переключает активный перед сессией / в меню. Аксессоры защитные: невалидный
/// `selectedID` (например, после удаления) откатывается на первый профиль.
public struct ProfileLibrary: Sendable, Codable, Equatable {
    public private(set) var profiles: [NamedProfile]
    public private(set) var selectedID: UUID?

    public init(profiles: [NamedProfile] = [], selectedID: UUID? = nil) {
        self.profiles = profiles
        // Нормализуем выбор сразу: невалидный id → первый профиль (или nil для пустой библиотеки).
        if let selectedID, profiles.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = profiles.first?.id
        }
    }

    public var isEmpty: Bool { profiles.isEmpty }

    /// Активный именованный профиль (или первый, если выбор сбит; nil только для пустой библиотеки).
    public var selected: NamedProfile? {
        guard let selectedID, let found = profiles.first(where: { $0.id == selectedID }) else {
            return profiles.first
        }
        return found
    }

    /// Профиль активного контекста для подсказок (пустой `UserProfile`, если библиотека пуста).
    public var activeProfile: UserProfile { selected?.profile ?? UserProfile() }

    // MARK: - Операции

    /// Добавить профиль; первый добавленный становится активным.
    @discardableResult
    public mutating func add(name: String, profile: UserProfile = UserProfile()) -> NamedProfile {
        let item = NamedProfile(name: name, profile: profile)
        profiles.append(item)
        if selectedID == nil { selectedID = item.id }
        return item
    }

    /// Удалить профиль; если удалили активный — активным становится первый из оставшихся.
    public mutating func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedID == id || !(profiles.contains { $0.id == selectedID }) {
            selectedID = profiles.first?.id
        }
    }

    /// Сделать профиль активным (no-op, если id неизвестен).
    public mutating func select(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Переименовать профиль.
    public mutating func rename(id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    /// Заменить содержимое профиля (секции `UserProfile`).
    public mutating func update(id: UUID, profile: UserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].profile = profile
    }

    // MARK: - Миграция

    /// Миграция со старого одиночного профиля: оборачиваем его в один именованный и делаем активным.
    public static func migrating(from legacy: UserProfile, defaultName: String = "Профиль") -> ProfileLibrary {
        var library = ProfileLibrary()
        library.add(name: defaultName, profile: legacy)
        return library
    }
}
