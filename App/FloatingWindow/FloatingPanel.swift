import AppKit
import CoreGraphics

/// Плавающее окно подсказок: очень высокий уровень окна, поверх всех окон (включая
/// fullscreen-приложения), не перехватывает фокус. Это тот случай, где SwiftUI-окна
/// недостаточно — нужен AppKit `NSPanel`.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, alwaysOnTop: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Уровень окна (настраивается): по умолчанию вежливый .floating — над обычными окнами
        // (в т.ч. над окном звонка), но НЕ над фуллскрином, чтобы не висеть поверх всего.
        // Опционально — assistive-tech-high: над всем, включая фуллскрин-приложения.
        level = Self.windowLevel(alwaysOnTop: alwaysOnTop)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Панель-утилита исключается из скриншотов/записи экрана (приватность, чтобы оверлей
        // не зашумлял захват). sharingType = .none убирает окно из ЛЕГАСИ-захвата
        // (CGWindowListCreateImage); современный ScreenCaptureKit снимает скомпонованный кадр
        // и может включать панель — поведение зависит от конкретного механизма захвата.
        sharingType = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        minSize = NSSize(width: 300, height: 180)   // окно можно растягивать (styleMask .resizable)
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        // Постоянная панель: не закрываем (нет пункта меню для повторного открытия) — сворачивание
        // делается шевроном внутри оверлея, скрытие — стелс-димом ⌘⇧H.
        standardWindowButton(.closeButton)?.isHidden = true
    }

    // Окно МОЖЕТ становиться ключевым — чтобы по клику работали выделение/копирование текста
    // подсказки (textSelection). `.nonactivatingPanel` + canBecomeMain=false означают: фокус
    // уходит на оверлей только по явному клику, а активным (frontmost) приложением остаётся
    // звонок — фокус у собеседования не отбираем.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Сменить «поверх всех окон» на лету — настройка применяется без перезапуска.
    func setAlwaysOnTop(_ on: Bool) {
        level = Self.windowLevel(alwaysOnTop: on)
    }

    /// .floating — над обычными окнами, но не над фуллскрином (вежливо). assistive-tech-high —
    /// над всем, включая фуллскрин-шаринг.
    private static func windowLevel(alwaysOnTop: Bool) -> NSWindow.Level {
        alwaysOnTop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
            : .floating
    }
}
