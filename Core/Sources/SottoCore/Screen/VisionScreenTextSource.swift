#if os(macOS)
import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Vision

/// Лёгкое описание окна для логики отбора — без зависимости от `SCWindow`,
/// чтобы выбор целевого окна был чистой функцией и покрывался Core-тестом.
///
/// Контракт порядка: массив `WindowCandidate` передаётся в том же порядке,
/// в каком `SCShareableContent` отдаёт `content.windows`. У ScreenCaptureKit это
/// фронт-первым (front-to-back) z-порядок: первый подходящий кандидат — самый
/// передний. Поэтому `selectTargetWindow` берёт первое окно, прошедшее эвристику.
public struct WindowCandidate: Equatable, Sendable {
    /// bundle id владельца окна (nil — система/без владельца).
    public let bundleID: String?
    /// Слой окна. 0 — обычный слой приложения; меню-бар, док, оверлеи имеют ненулевой слой.
    public let layer: Int
    /// Рамка окна в ПУНКТАХ (как отдаёт `SCWindow.frame`).
    public let frame: CGRect
    /// Окно сейчас на экране (видимо), не свёрнуто.
    public let isOnScreen: Bool

    public init(bundleID: String?, layer: Int, frame: CGRect, isOnScreen: Bool) {
        self.bundleID = bundleID
        self.layer = layer
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

/// Минимальная площадь окна (в пунктах²), ниже которой окно считаем палитрой/тултипом
/// и пропускаем. 200×200 — заведомо меньше любого окна задачи (IDE/браузер/терминал),
/// но крупнее палитр, всплывашек автодополнения и тултипов.
let kMinTargetWindowArea: CGFloat = 200 * 200

/// Чистая логика отбора целевого окна задачи.
///
/// Берёт первое (самое переднее по контракту порядка) окно, которое:
///  - не принадлежит нашему приложению (`bundleID` не входит в `excludeBundleIDs`);
///  - на обычном слое приложения (`layer == 0`) — отсекает меню-бар/док/оверлеи;
///  - на экране (`isOnScreen`);
///  - достаточно крупное (площадь `frame` ≥ `kMinTargetWindowArea`) — отсекает палитры/тултипы.
///
/// Окна с нестандартным уровнем (floating/utility-панели, иногда полноэкранные пространства)
/// намеренно не проходят `layer == 0` и уходят в фоллбэк на весь дисплей — это безопаснее
/// пустого захвата; при необходимости порог по слою можно ослабить.
///
/// Возвращает `nil`, если подходящего окна нет — вызывающая сторона уходит в фоллбэк
/// на захват всего дисплея (никогда не «ничего не захвачено»).
func selectTargetWindow(
    from candidates: [WindowCandidate],
    excludeBundleIDs: [String]
) -> WindowCandidate? {
    candidates.first { candidate in
        guard candidate.isOnScreen else { return false }
        guard candidate.layer == 0 else { return false }
        if let bundleID = candidate.bundleID, excludeBundleIDs.contains(bundleID) { return false }
        let area = candidate.frame.width * candidate.frame.height
        guard area >= kMinTargetWindowArea else { return false }
        return true
    }
}

/// Реальный источник текста с экрана: захватывает экран через ScreenCaptureKit
/// (исключая окна самого приложения, чтобы не распознавать собственный оверлей) и
/// распознаёт текст через Vision — локально, на устройстве, без сети.
///
/// По умолчанию захватывается ВЕСЬ дисплей — это надёжно и проверено. Сужение до одного
/// окна задачи (`preferWindowCapture`) убрало бы из OCR мусор (меню-бар, док, вкладки IDE),
/// НО опирается на недокументированное допущение о порядке `content.windows` (фронт-первым).
/// На практике это давало захват НЕ того окна (фон/пустое) → OCR без кода → разбор «не видит
/// код». Поэтому сужение по умолчанию ВЫКЛЮЧЕНО; включать только после проверки на живом
/// экране, когда переднее окно будет определяться надёжным сигналом, а не порядком массива.
///
/// `CGImage` живёт только внутри методов этого типа и не пересекает границы актёров.
public struct VisionScreenTextSource: ScreenTextSource {
    private let excludeBundleIDs: [String]
    private let recognitionLanguages: [String]
    /// Сужать захват до переднего окна задачи (см. оговорку выше). По умолчанию `false` —
    /// захват всего дисплея, чтобы код гарантированно попадал в OCR.
    private let preferWindowCapture: Bool

    public init(
        excludeBundleIDs: [String] = [],
        recognitionLanguages: [String] = ["en-US", "ru-RU"],
        preferWindowCapture: Bool = false
    ) {
        self.excludeBundleIDs = excludeBundleIDs
        self.recognitionLanguages = recognitionLanguages
        self.preferWindowCapture = preferWindowCapture
    }

    public func recognizeScreenText(region: CaptureRegion?) async throws -> RecognizedScreen {
        // Не доверяем CGPreflightScreenCaptureAccess() — у dev-сборок (ad-hoc подпись)
        // он врёт «нет доступа». Просто пробуем захват: реальный TCC-чек сделает система.
        let image: CGImage
        if let region {
            image = try await captureRegion(region)
        } else {
            image = try await captureActiveDisplay()
        }
        let text = try Self.recognizeText(in: image, languages: recognitionLanguages)
        return RecognizedScreen(text: text)
    }

    /// Прицельный захват выбранной области (как Cmd+Shift+4): снимаем ВЕСЬ дисплей надёжным,
    /// проверенным путём (он уже исключает наши окна), затем ВЫРЕЗАЕМ прямоугольник из готового
    /// кадра. Это намеренно надёжнее недокументированного `SCStreamConfiguration.sourceRect` —
    /// ровно тот класс хрупких допущений, что уже стрелял с порядком окон (см. историю типа).
    private func captureRegion(_ region: CaptureRegion) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenTextSourceError.permissionDenied
        }
        // Дисплей, на котором выбрана область (по displayID); если вдруг не нашли — первый.
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
            ?? content.displays.first else {
            throw ScreenTextSourceError.permissionDenied
        }

        let full = try await captureFullDisplay(display, content: content)
        // Масштаб пиксели/пункты — из самого кадра и точечных размеров дисплея (без NSScreen в Core).
        // `SCDisplay.frame` — в пунктах, `full.width/height` — в пикселях нативного разрешения.
        let scaleX = display.frame.width > 0 ? CGFloat(full.width) / display.frame.width : 1
        let scaleY = display.frame.height > 0 ? CGFloat(full.height) / display.frame.height : 1
        let px = pixelRect(
            forPointRect: region.rect,
            scaleX: scaleX, scaleY: scaleY,
            imageWidth: full.width, imageHeight: full.height
        )
        // Вырожденная область или неудачный кроп — не регрессируем в «ничего», отдаём весь дисплей.
        guard !px.isNull, px.width >= 1, px.height >= 1, let cropped = full.cropping(to: px) else {
            return full
        }
        return cropped
    }

    private func captureActiveDisplay() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Самая частая причина — нет доступа к записи экрана.
            throw ScreenTextSourceError.permissionDenied
        }
        guard let display = content.displays.first else { throw ScreenTextSourceError.permissionDenied }

        // Сужение до переднего окна — только по явному флагу (по умолчанию выключено).
        // Маппим SCWindow -> WindowCandidate и отдаём чистой функции отбора. ВАЖНО: порядок
        // content.windows как «фронт-первым» — недокументированное допущение; пока не проверим
        // на живом экране, default-путь — захват всего дисплея (код гарантированно в OCR).
        if preferWindowCapture {
            let candidates = content.windows.map { window in
                WindowCandidate(
                    bundleID: window.owningApplication?.bundleIdentifier,
                    layer: window.windowLayer,
                    frame: window.frame,
                    isOnScreen: window.isOnScreen
                )
            }
            if let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: excludeBundleIDs),
               // Сопоставляем выбранного кандидата обратно с реальным SCWindow по ИНДЕКСУ:
               // `candidates` построен `content.windows.map`, порядок 1:1, поэтому индекс кандидата
               // совпадает с индексом окна. `firstIndex(of:)` согласован с выбором (обе функции берут
               // «первое подходящее»): даже если два окна одного приложения совпадают по всем полям,
               // вернётся ровно то окно, что прошло эвристику.
               let idx = candidates.firstIndex(of: chosen) {
                let targetWindow = content.windows[idx]
                do {
                    return try await captureWindow(targetWindow)
                } catch {
                    // Захват окна не удался — не регрессируем в «ничего», уходим в фоллбэк на дисплей.
                }
            }
        }

        // Захват всего дисплея (надёжный путь по умолчанию), исключая окна самого приложения
        // (наш оверлей), чтобы они не попали в OCR.
        return try await captureFullDisplay(display, content: content)
    }

    /// Захват одного окна целиком, независимо от дисплея.
    private func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        // Размер кадра — в ПИКСЕЛЯХ. Берём contentRect (пункты) фильтра и масштаб
        // pointPixelScale, заданный самим фильтром под физический дисплей окна. Так кадр
        // получается в нативном разрешении (Retina), без размытия и без апскейла —
        // это важно для качества OCR мелкого кода. Оба свойства доступны с macOS 14,
        // у нас таргет macOS 15, поэтому без #available.
        let scale = filter.pointPixelScale
        let pixelWidth = Int((filter.contentRect.width * CGFloat(scale)).rounded())
        let pixelHeight = Int((filter.contentRect.height * CGFloat(scale)).rounded())
        // Подстраховка от нулевых/отрицательных размеров вырожденного окна.
        config.width = max(pixelWidth, 1)
        config.height = max(pixelHeight, 1)
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenTextSourceError.captureFailed(error.localizedDescription)
        }
    }

    /// Фоллбэк-захват всего дисплея (как было до сужения до окна).
    private func captureFullDisplay(_ display: SCDisplay, content: SCShareableContent) async throws -> CGImage {
        // Исключаем окна самого приложения (наш оверлей и пр.), чтобы не попадали в OCR.
        let excluded = content.applications.filter { excludeBundleIDs.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.ignoreShadowsDisplay = true

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenTextSourceError.captureFailed(error.localizedDescription)
        }
    }

    /// Синхронный OCR (Vision). Вызывается из nonisolated async-метода — выполняется вне
    /// актёра, поэтому не блокирует его исполнитель.
    private static func recognizeText(in image: CGImage, languages: [String]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false      // код не «исправляем» автокоррекцией
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        // Порядок чтения: сверху-вниз (y больше — выше), затем слева-направо.
        let lines = observations
            .sorted { a, b in
                if abs(a.boundingBox.origin.y - b.boundingBox.origin.y) > 0.012 {
                    return a.boundingBox.origin.y > b.boundingBox.origin.y
                }
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
#endif
