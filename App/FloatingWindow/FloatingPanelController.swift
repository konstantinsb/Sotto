import AppKit
import SwiftUI

/// Управляет жизненным циклом плавающего окна. SwiftUI-контент встраивается через
/// `NSHostingView` (SwiftUI внутри AppKit-панели).
@MainActor
final class FloatingPanelController {
    private var panel: FloatingPanel?
    private let environment: AppEnvironment

    /// Имя автосейва кадра — позиция и размер панели запоминаются между запусками (AppKit).
    private let frameAutosaveName = "SottoOverlayPanel"
    /// Высота развёрнутой панели по умолчанию (старт нового окна и восстановление высоты).
    private let defaultExpandedHeight: CGFloat = 320

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        if let panel { panel.orderFrontRegardless(); return }   // идемпотентно
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: defaultExpandedHeight),
            alwaysOnTop: environment.overlayAlwaysOnTop
        )
        let host = NSHostingView(rootView: SuggestionOverlayView().environment(environment))
        host.autoresizingMask = [.width, .height]   // контент следует за размером панели
        panel.contentView = host
        // Запоминаем позицию/размер между запусками. setFrameUsingName восстанавливает кадр;
        // если сохранённого нет — ставим панель в правый верх экрана.
        panel.setFrameAutosaveName(frameAutosaveName)
        if panel.setFrameUsingName(frameAutosaveName) {
            // Подстраховка от крошечного сохранённого кадра (напр. от прежней свёртки) —
            // возвращаем вменяемую высоту.
            if panel.frame.height < defaultExpandedHeight * 0.5 {
                setPanelHeight(defaultExpandedHeight, of: panel, animate: false)
            }
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 440, y: frame.maxY - 40))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Глобальный показать/скрыть (⌥⌘\): orderOut/orderFront без уничтожения панели — повторный
    /// показ мгновенный и сохраняет позицию. Если панели ещё нет — создаём.
    func toggleVisibility() {
        guard let panel else { show(); return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    /// Скрыть панель с экрана без уничтожения (orderOut) — повторный показ мгновенный, кадр цел.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Применить настройку «поверх всех окон» к уже открытой панели (без перезапуска).
    func setAlwaysOnTop(_ on: Bool) {
        panel?.setAlwaysOnTop(on)
    }

    /// Сменить высоту панели, удерживая верхний-левый угол: бар остаётся на месте, ужимается низ.
    private func setPanelHeight(_ height: CGFloat, of panel: FloatingPanel, animate: Bool) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: animate)
    }
}
