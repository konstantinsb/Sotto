import SwiftUI

/// Точка входа. Приложение живёт в menu bar (без окна и иконки в Dock).
@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra("Sotto", systemImage: "waveform") {
            MenuBarView()
                .environment(environment)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(environment)
        }

        Window("Профиль", id: "profile") {
            ProfileView()
                .environment(environment)
        }
        .defaultSize(width: 560, height: 640)

        Window("Summary разговора", id: "summary") {
            SummaryView()
                .environment(environment)
        }
        .defaultSize(width: 560, height: 520)

        Window("История", id: "history") {
            HistoryView()
                .environment(environment)
        }
        .defaultSize(width: 680, height: 520)
    }
}
