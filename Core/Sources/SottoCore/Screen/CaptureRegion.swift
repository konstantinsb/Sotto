import Foundation
import CoreGraphics

/// Прямоугольная область экрана для прицельного захвата+OCR (как Cmd+Shift+4).
///
/// Координаты — в ПУНКТАХ, начало в ВЕРХНЕМ-ЛЕВОМ углу СВОЕГО дисплея (как у
/// CoreGraphics/ScreenCaptureKit), а не в AppKit-нижнем-левом. Привязка к дисплею — по
/// `displayID`, чтобы корректно работать на мультидисплее (выделили на втором мониторе —
/// и захват пойдёт с него).
///
/// `Sendable` (только число + `CGRect`) — безопасно переносится с главного актёра, где
/// рисуется выделение, в актёр разбора экрана.
public struct CaptureRegion: Sendable, Equatable {
    /// `CGDirectDisplayID` дисплея, на котором выбрана область.
    public let displayID: UInt32
    /// Прямоугольник в пунктах, относительно верхнего-левого угла этого дисплея.
    public let rect: CGRect

    public init(displayID: UInt32, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}

/// Перевод прямоугольника выделения из глобальных координат AppKit (начало в нижнем-левом
/// углу основного экрана, ось Y вверх) в координаты, относительные верхнего-левого угла
/// дисплея (ось Y вниз) — как ждёт захват экрана. Чистая функция: тестируется без UI.
///
/// - Parameters:
///   - rect: выделение в глобальных координатах AppKit (нижний-левый origin).
///   - screenFrame: `NSScreen.frame` целевого экрана в тех же глобальных координатах.
/// - Returns: прямоугольник в пунктах, относительно верхнего-левого угла этого дисплея.
public func displayRelativeTopLeftRect(
    globalBottomLeftRect rect: CGRect,
    screenFrame: CGRect
) -> CGRect {
    let relativeX = rect.minX - screenFrame.minX
    // Верх выделения в AppKit — это maxY (ось вверх). Расстояние от верхней кромки экрана до
    // верха выделения = screenFrame.maxY - rect.maxY → это и есть Y в системе с началом сверху.
    let relativeY = screenFrame.maxY - rect.maxY
    return CGRect(x: relativeX, y: relativeY, width: rect.width, height: rect.height)
}

/// Перевод прямоугольника из пунктов (верхний-левый origin, относительно дисплея) в ПИКСЕЛИ
/// захваченного изображения этого дисплея, с обрезкой по границам кадра. Чистая функция —
/// покрыта тестом; нужна, чтобы вырезать выбранную область из полного снимка дисплея
/// (надёжнее недокументированного `SCStreamConfiguration.sourceRect`).
///
/// Возвращает `CGRect.null`, если область не пересекается с кадром (вырожденный случай) —
/// вызывающая сторона тогда отдаёт весь снимок, чтобы не регрессировать в «ничего».
public func pixelRect(
    forPointRect pointRect: CGRect,
    scaleX: CGFloat,
    scaleY: CGFloat,
    imageWidth: Int,
    imageHeight: Int
) -> CGRect {
    let raw = CGRect(
        x: pointRect.minX * scaleX,
        y: pointRect.minY * scaleY,
        width: pointRect.width * scaleX,
        height: pointRect.height * scaleY
    )
    // Обрезаем по кадру: `CGImage.cropping(to:)` с выходом за границы вернул бы nil.
    let bounds = CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight))
    let clipped = raw.intersection(bounds)
    return clipped.isNull ? .null : clipped.integral
}
