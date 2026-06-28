import AppKit

/// Делегат приложения. Режим `.accessory` — без иконки в Dock (agent-приложение).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
