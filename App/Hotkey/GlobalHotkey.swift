import AppKit
import Carbon.HIToolbox

/// Глобальный системный хоткей на Carbon (`RegisterEventHotKey`) — срабатывает, даже
/// когда сфокусировано другое приложение (браузер/IDE). Без сторонних зависимостей.
/// Действие вызывается на главном акторе.
///
/// C-обработчик событий не может захватывать контекст, поэтому инстансы хранятся в
/// статическом реестре по id хоткея, а обработчик диспатчит по нему на главный поток.
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private let action: @MainActor () -> Void
    private let id: UInt32

    // Реестр и счётчик id — трогаем только с главного потока (регистрация и диспатч).
    nonisolated(unsafe) private static var registry: [UInt32: GlobalHotkey] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    /// Маска модификаторов ⌥⌘ и код клавиши «S» (kVK_ANSI_S) — для удобства вызова без
    /// импорта Carbon в App-слое.
    static let optionCommandMask = UInt32(optionKey | cmdKey)
    static let keyS = UInt32(kVK_ANSI_S)
    /// Клавиша «\» — глобальный показать/скрыть оверлей (⌥⌘\).
    /// ⌥⌘H не берём — это системное «Скрыть остальные».
    static let keyBackslash = UInt32(kVK_ANSI_Backslash)

    /// `keyCode` — виртуальный код клавиши; `modifiers` — маски Carbon (cmdKey, optionKey…).
    /// Возвращает nil, если регистрация не удалась (например, комбинация занята).
    @MainActor
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.id = Self.nextID
        Self.nextID += 1
        Self.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("SOTT"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private func fire() {
        let action = self.action
        Task { @MainActor in action() }
    }

    fileprivate static func dispatch(id: UInt32) {
        registry[id]?.fire()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, nil)
    }

    private static func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for byte in string.utf8.prefix(4) { result = (result << 8) + OSType(byte) }
        return result
    }
}

/// Топ-уровневый C-обработчик: читает id хоткея и диспатчит на главный поток.
private func hotkeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async { GlobalHotkey.dispatch(id: id) }
    return noErr
}
