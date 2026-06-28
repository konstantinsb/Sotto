import Foundation
import SottoCore

/// Персистентность профилей: JSON шифруется (CryptoBox/AES-GCM) и кладётся в UserDefaults.
/// Хранит библиотеку именованных профилей; со старого одиночного профиля мигрирует один раз.
struct ProfileStore {
    private let legacyKey = "sotto.user.profile.enc"     // старый одиночный профиль
    private let libraryKey = "sotto.user.profiles.enc"   // библиотека именованных профилей
    private let defaults: UserDefaults
    private let crypto = CryptoBox.appBox()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Загрузить библиотеку. Если её ещё нет — мигрировать старый одиночный профиль
    /// (или завести один пустой профиль по умолчанию) и сохранить.
    func loadLibrary() -> ProfileLibrary {
        if let blob = defaults.data(forKey: libraryKey),
           let json = crypto.decryptData(blob),
           let library = try? JSONDecoder().decode(ProfileLibrary.self, from: json) {
            return library
        }
        let library: ProfileLibrary
        let legacy = loadLegacy()
        if !legacy.isEmpty {
            library = ProfileLibrary.migrating(from: legacy)   // перенос прежнего профиля
        } else {
            var seeded = ProfileLibrary()
            seeded.add(name: "Профиль")                        // всегда есть что редактировать
            library = seeded
        }
        saveLibrary(library)
        return library
    }

    func saveLibrary(_ library: ProfileLibrary) {
        guard let json = try? JSONEncoder().encode(library),
              let blob = crypto.encrypt(json) else { return }
        defaults.set(blob, forKey: libraryKey)
    }

    /// Прочитать старый одиночный профиль (для одноразовой миграции).
    private func loadLegacy() -> UserProfile {
        guard let blob = defaults.data(forKey: legacyKey),
              let json = crypto.decryptData(blob),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: json) else {
            return UserProfile()
        }
        return profile
    }
}
