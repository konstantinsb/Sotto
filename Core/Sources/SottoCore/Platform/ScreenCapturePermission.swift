import CoreGraphics

/// Доступ к записи экрана (TCC, «Запись экрана»). В отличие от микрофона строка в
/// Info.plist не требуется — систему запрашивает сам захват. При первом гранте macOS
/// обычно требует перезапуск приложения, прежде чем захват начнёт отдавать кадры.
public enum ScreenCapturePermission {
    /// Уже выдан доступ? (проверка без показа диалога)
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Запросить доступ. Возвращает true, если выдан сейчас или ранее.
    @discardableResult
    public static func request() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
