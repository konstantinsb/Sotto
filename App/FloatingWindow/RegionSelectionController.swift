import AppKit
import CoreGraphics
import SottoCore

/// Результат выбора области экрана: готовые координаты для прицельного захвата.
struct RegionSelection {
    let region: CaptureRegion
}

/// Стелс-оверлей выбора прямоугольной области экрана — как Cmd+Shift+4, но рамку и затемнение
/// рисуем СВОИМ окном с `sharingType = .none`, чтобы они НЕ попадали в шаринг экрана собеседнику.
/// Нативный `screencapture -i` отвергнут: его крестик/рамка попадают в сам захват.
///
/// Окно растянуто на ОБЪЕДИНЕНИЕ всех экранов (мультидисплей в одной системе координат AppKit);
/// по завершении определяем дисплей по центру выделения и переводим координаты в захватные
/// (`displayRelativeTopLeftRect` из Core). Панель `.nonactivatingPanel` — не отбираем активный
/// статус у окна звонка (стелс), но становимся key, чтобы ловить Esc.
@MainActor
final class RegionSelectionController {
    private var panel: RegionSelectionPanel?
    private var continuation: CheckedContinuation<RegionSelection?, Never>?
    private var keyMonitor: Any?

    /// Показать оверлей и дождаться выбора. Возвращает `nil` при отмене (Esc, слишком мелкое
    /// выделение, нет экранов). Повторный вызов во время активного выбора — сразу `nil`
    /// (не плодим оверлеи).
    func selectRegion() async -> RegionSelection? {
        if panel != nil { return nil }
        guard !NSScreen.screens.isEmpty else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<RegionSelection?, Never>) in
            self.continuation = cont
            self.present()
        }
    }

    private func present() {
        // Объединение всех экранов — единая система координат AppKit (нижний-левый origin).
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let panel = RegionSelectionPanel(contentRect: union)
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: union.size))
        view.autoresizingMask = [.width, .height]
        view.onComplete = { [weak self] localRect in
            self?.finish(localRectInUnion: localRect, unionOrigin: union.origin)
        }
        view.onCancel = { [weak self] in
            self?.finish(localRectInUnion: nil, unionOrigin: union.origin)
        }
        panel.contentView = view
        panel.setFrame(union, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)

        // Esc — резервный путь, если keyDown не дойдёт до view: локальный монитор гасит событие.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // Esc
                self?.finish(localRectInUnion: nil, unionOrigin: union.origin)
                return nil
            }
            return event
        }
        self.panel = panel
    }

    private func finish(localRectInUnion: CGRect?, unionOrigin: CGPoint) {
        // Гонок нет (всё на главном актёре), но защищаемся от повторного резюма континуэйшна.
        guard let cont = continuation else { return }
        continuation = nil

        // Снимаем монитор и закрываем оверлей ДО выдачи результата — чтобы наш оверлей точно
        // не попал в последующий захват (плюс он и так исключён по bundleID в источнике).
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil

        guard let local = localRectInUnion else { cont.resume(returning: nil); return }
        // Из координат окна (== объединение экранов, локальный origin) в глобальные AppKit.
        let global = CGRect(
            x: local.minX + unionOrigin.x,
            y: local.minY + unionOrigin.y,
            width: local.width, height: local.height
        )
        // Слишком мелкое выделение (случайный клик/дрожь) — отмена, чтобы не гнать пустой OCR.
        guard global.width >= 8, global.height >= 8 else { cont.resume(returning: nil); return }

        // Дисплей по центру выделения (мультидисплей); если не попали — основной.
        let center = CGPoint(x: global.midX, y: global.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let displayID = screen.sottoDisplayID else {
            cont.resume(returning: nil); return
        }
        let relative = displayRelativeTopLeftRect(globalBottomLeftRect: global, screenFrame: screen.frame)
        let region = CaptureRegion(displayID: displayID, rect: relative)
        cont.resume(returning: RegionSelection(region: region))
    }
}

private extension NSScreen {
    /// `CGDirectDisplayID` экрана из его deviceDescription (ключ `NSScreenNumber`).
    var sottoDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Полноэкранная стелс-панель под выбор области. `.nonactivatingPanel` — не активируем
/// приложение (фокус остаётся у звонка), но можем стать key для Esc; `sharingType = .none` —
/// не попадаем в шаринг экрана; уровень — выше панели подсказок, чтобы выделение было поверх.
final class RegionSelectionPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Вью выбора области: затемняет экран, по drag рисует «дырку» (выделение без затемнения) и
/// рамку, по mouseUp отдаёт прямоугольник (в координатах вью), по Esc/пустому клику — отмену.
final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // нижний-левый origin (AppKit) — как ждёт конвертер

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, p.x),
            y: min(start.y, p.y),
            width: abs(p.x - start.x),
            height: abs(p.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        currentRect = .zero
        needsDisplay = true
        // Реальный дрэг → отдаём прямоугольник; чистый клик без движения → отмена.
        if rect.width >= 1, rect.height >= 1 {
            onComplete?(rect)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Затемняем весь экран — лёгкая вуаль, чтобы выделяемая область читалась.
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        // Вырезаем «дырку»: внутри выделения экран виден без затемнения (.clear composite
        // работает в буфере непрозрачного-в-false окна — классический приём оверлея выделения).
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear
        currentRect.fill()
        ctx.restoreGraphicsState()

        // Рамка вокруг выделения.
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1
        border.stroke()
    }
}
