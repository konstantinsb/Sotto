#if os(macOS)
import XCTest
import CoreGraphics
@testable import SottoCore

/// Тесты чистой математики выбора области экрана: перевод координат выделения (AppKit,
/// нижний-левый origin) в дисплей-относительные координаты с началом сверху и далее в пиксели
/// захваченного кадра. Реальный захват/кроп ScreenCaptureKit проверяется вручную на живом
/// экране — здесь покрываем только конверсии, мультидисплей и обрезку по границам.
final class ScreenRegionTests: XCTestCase {

    // MARK: - displayRelativeTopLeftRect

    func testTopLeftConversionOnPrimaryScreen() {
        // Основной экран 1440×900, начало в (0,0). Выделение в AppKit (нижний-левый):
        // нижняя кромка y=700, высота 50 → верх в AppKit = 750.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 700, width: 200, height: 50)
        let result = displayRelativeTopLeftRect(globalBottomLeftRect: selection, screenFrame: screen)
        // X не меняется (экран в нуле). Y сверху = 900 - 750 = 150.
        XCTAssertEqual(result, CGRect(x: 100, y: 150, width: 200, height: 50))
    }

    func testTopLeftConversionOnSecondaryScreenToTheRight() {
        // Второй монитор 1920×1080 справа от основного: его frame начинается с x=1440.
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 1500, y: 900, width: 300, height: 100)
        let result = displayRelativeTopLeftRect(globalBottomLeftRect: selection, screenFrame: screen)
        // X относительно дисплея = 1500 - 1440 = 60. Y сверху = 1080 - (900 + 100) = 80.
        XCTAssertEqual(result, CGRect(x: 60, y: 80, width: 300, height: 100))
    }

    func testTopLeftConversionWithNegativeOriginScreen() {
        // Монитор слева/ниже основного (отрицательный origin) — частый мультидисплей-кейс.
        let screen = CGRect(x: -1280, y: -100, width: 1280, height: 800)
        let selection = CGRect(x: -1200, y: 500, width: 100, height: 100)
        let result = displayRelativeTopLeftRect(globalBottomLeftRect: selection, screenFrame: screen)
        // X = -1200 - (-1280) = 80. maxY экрана = -100 + 800 = 700; верх выделения = 600.
        // Y сверху = 700 - 600 = 100.
        XCTAssertEqual(result, CGRect(x: 80, y: 100, width: 100, height: 100))
    }

    // MARK: - pixelRect

    func testPixelRectRetinaScale() {
        // Retina ×2: пункты → пиксели умножением на масштаб, кадр заведомо больше области.
        let result = pixelRect(
            forPointRect: CGRect(x: 10, y: 20, width: 100, height: 50),
            scaleX: 2, scaleY: 2, imageWidth: 2880, imageHeight: 1800
        )
        XCTAssertEqual(result, CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    func testPixelRectNonRetinaScale() {
        let result = pixelRect(
            forPointRect: CGRect(x: 5, y: 5, width: 40, height: 30),
            scaleX: 1, scaleY: 1, imageWidth: 1440, imageHeight: 900
        )
        XCTAssertEqual(result, CGRect(x: 5, y: 5, width: 40, height: 30))
    }

    func testPixelRectClampedToImageBounds() {
        // Область частично выходит за правый/нижний край — обрезается по кадру.
        let result = pixelRect(
            forPointRect: CGRect(x: 1400, y: 880, width: 100, height: 50),
            scaleX: 1, scaleY: 1, imageWidth: 1440, imageHeight: 900
        )
        XCTAssertEqual(result, CGRect(x: 1400, y: 880, width: 40, height: 20))
    }

    func testPixelRectFullyOutsideReturnsNull() {
        // Полностью вне кадра — null, вызывающая сторона отдаст весь снимок.
        let result = pixelRect(
            forPointRect: CGRect(x: 5000, y: 5000, width: 100, height: 100),
            scaleX: 1, scaleY: 1, imageWidth: 1440, imageHeight: 900
        )
        XCTAssertTrue(result.isNull)
    }

    func testPixelRectRoundsToIntegralPixels() {
        // Дробный масштаб (1.5) → целочисленные границы пикселей (integral).
        let result = pixelRect(
            forPointRect: CGRect(x: 10, y: 10, width: 33, height: 33),
            scaleX: 1.5, scaleY: 1.5, imageWidth: 2000, imageHeight: 2000
        )
        // Кадр большой, обрезки нет; проверяем только целочисленность.
        XCTAssertEqual(result, result.integral)
        XCTAssertEqual(result.minX, result.minX.rounded(.down))
    }

    // MARK: - CaptureRegion

    func testCaptureRegionEquatable() {
        let a = CaptureRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = CaptureRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let c = CaptureRegion(displayID: 2, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
#endif
