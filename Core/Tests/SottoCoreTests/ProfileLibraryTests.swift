import XCTest
@testable import SottoCore

final class ProfileLibraryTests: XCTestCase {

    func testAddSelectsFirstAutomatically() {
        var lib = ProfileLibrary()
        XCTAssertTrue(lib.isEmpty)
        let a = lib.add(name: "Резюме iOS")
        XCTAssertEqual(lib.selectedID, a.id)         // первый стал активным
        let b = lib.add(name: "Стек")
        XCTAssertEqual(lib.selectedID, a.id)         // второй активным не делает
        XCTAssertEqual(lib.profiles.count, 2)
        XCTAssertEqual(lib.selected?.id, a.id)
        _ = b
    }

    func testSelectChangesActive() {
        var lib = ProfileLibrary()
        lib.add(name: "A")
        let b = lib.add(name: "B")
        lib.select(id: b.id)
        XCTAssertEqual(lib.selected?.name, "B")
        XCTAssertEqual(lib.activeProfile, b.profile)
    }

    func testSelectIgnoresUnknownID() {
        var lib = ProfileLibrary()
        let a = lib.add(name: "A")
        lib.select(id: UUID())
        XCTAssertEqual(lib.selectedID, a.id)         // выбор не сбит
    }

    func testRemoveActiveReselectsFirst() {
        var lib = ProfileLibrary()
        let a = lib.add(name: "A")
        let b = lib.add(name: "B")
        lib.select(id: b.id)
        lib.remove(id: b.id)
        XCTAssertEqual(lib.selected?.id, a.id)        // активным снова первый
        lib.remove(id: a.id)
        XCTAssertNil(lib.selectedID)                  // пусто
        XCTAssertEqual(lib.activeProfile, UserProfile())
    }

    func testRenameAndUpdate() {
        var lib = ProfileLibrary()
        let a = lib.add(name: "A")
        lib.rename(id: a.id, to: "Резюме")
        XCTAssertEqual(lib.profiles.first?.name, "Резюме")
        let newProfile = UserProfile(about: "5 лет iOS", stack: "Swift")
        lib.update(id: a.id, profile: newProfile)
        XCTAssertEqual(lib.selected?.profile, newProfile)
    }

    func testMigrationWrapsLegacyProfile() {
        let legacy = UserProfile(about: "опыт", projects: "проект", stack: "Swift", starStories: "star")
        let lib = ProfileLibrary.migrating(from: legacy)
        XCTAssertEqual(lib.profiles.count, 1)
        XCTAssertEqual(lib.selected?.profile, legacy)
        XCTAssertEqual(lib.selected?.name, "Профиль")
        XCTAssertEqual(lib.activeProfile, legacy)
    }

    func testCodableRoundTrip() throws {
        var lib = ProfileLibrary()
        lib.add(name: "A", profile: UserProfile(about: "a"))
        let b = lib.add(name: "B", profile: UserProfile(about: "b"))
        lib.select(id: b.id)
        let data = try JSONEncoder().encode(lib)
        let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: data)
        XCTAssertEqual(decoded, lib)
        XCTAssertEqual(decoded.selected?.name, "B")
    }

    func testSelectedFallsBackWhenIDInvalidAfterDecode() {
        // Симулируем «битый» selectedID (профиль удалён вне нормализатора).
        let a = NamedProfile(name: "A")
        let lib = ProfileLibrary(profiles: [a], selectedID: UUID())
        XCTAssertEqual(lib.selectedID, a.id)          // init нормализовал
        XCTAssertEqual(lib.selected?.id, a.id)
    }
}
