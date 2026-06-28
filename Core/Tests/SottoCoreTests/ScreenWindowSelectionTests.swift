#if os(macOS)
import XCTest
import CoreGraphics
@testable import SottoCore

/// Тесты чистой логики отбора целевого окна задачи (`selectTargetWindow`).
/// Реальный захват ScreenCaptureKit проверяется вручную на живом экране — здесь
/// покрываем только эвристику выбора и контракт фоллбэка (nil -> захват дисплея).
final class ScreenWindowSelectionTests: XCTestCase {

    private let ours = ["com.sotto.app"]

    /// Достаточно крупная рамка, заведомо проходящая порог площади.
    private func bigFrame() -> CGRect { CGRect(x: 0, y: 0, width: 1200, height: 800) }

    func testFrontmostNormalForeignWindowIsSelected() {
        let candidates = [
            WindowCandidate(bundleID: "com.apple.dt.Xcode", layer: 0, frame: bigFrame(), isOnScreen: true),
            WindowCandidate(bundleID: "com.google.Chrome", layer: 0, frame: bigFrame(), isOnScreen: true),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        // Фронт-первым: первый подходящий кандидат — самый передний.
        XCTAssertEqual(chosen?.bundleID, "com.apple.dt.Xcode")
    }

    func testOwnApplicationIsSkipped() {
        let candidates = [
            WindowCandidate(bundleID: "com.sotto.app", layer: 0, frame: bigFrame(), isOnScreen: true),
            WindowCandidate(bundleID: "com.apple.dt.Xcode", layer: 0, frame: bigFrame(), isOnScreen: true),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        // Наш оверлей пропускается, выбирается окно задачи позади него.
        XCTAssertEqual(chosen?.bundleID, "com.apple.dt.Xcode")
    }

    func testNonZeroLayerWindowIsSkipped() {
        // Меню-бар/док и оверлеи живут на ненулевом слое.
        let candidates = [
            WindowCandidate(bundleID: "com.apple.controlcenter", layer: 25, frame: bigFrame(), isOnScreen: true),
            WindowCandidate(bundleID: "com.apple.dt.Xcode", layer: 0, frame: bigFrame(), isOnScreen: true),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        XCTAssertEqual(chosen?.bundleID, "com.apple.dt.Xcode")
    }

    func testTooSmallWindowIsSkipped() {
        // Палитра/тултип — ниже порога площади, пропускается.
        let palette = CGRect(x: 0, y: 0, width: 120, height: 80)
        let candidates = [
            WindowCandidate(bundleID: "com.apple.dt.Xcode", layer: 0, frame: palette, isOnScreen: true),
            WindowCandidate(bundleID: "com.google.Chrome", layer: 0, frame: bigFrame(), isOnScreen: true),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        XCTAssertEqual(chosen?.bundleID, "com.google.Chrome")
    }

    func testOffScreenWindowIsSkipped() {
        let candidates = [
            WindowCandidate(bundleID: "com.apple.dt.Xcode", layer: 0, frame: bigFrame(), isOnScreen: false),
            WindowCandidate(bundleID: "com.google.Chrome", layer: 0, frame: bigFrame(), isOnScreen: true),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        XCTAssertEqual(chosen?.bundleID, "com.google.Chrome")
    }

    func testEmptyListReturnsNilForFallback() {
        let chosen = selectTargetWindow(from: [], excludeBundleIDs: ours)
        // nil -> вызывающая сторона уходит в фоллбэк на захват всего дисплея.
        XCTAssertNil(chosen)
    }

    func testNoSuitableWindowReturnsNilForFallback() {
        // Все кандидаты отсеяны (наше окно + мелкое + не на экране) -> nil -> фоллбэк.
        let small = CGRect(x: 0, y: 0, width: 50, height: 50)
        let candidates = [
            WindowCandidate(bundleID: "com.sotto.app", layer: 0, frame: bigFrame(), isOnScreen: true),
            WindowCandidate(bundleID: "com.apple.dt.Xcode", layer: 0, frame: small, isOnScreen: true),
            WindowCandidate(bundleID: "com.google.Chrome", layer: 0, frame: bigFrame(), isOnScreen: false),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        XCTAssertNil(chosen)
    }

    func testWindowWithNilBundleIDIsEligible() {
        // bundleID может быть nil (нет владельца) — это не наше приложение, окно допустимо.
        let candidates = [
            WindowCandidate(bundleID: nil, layer: 0, frame: bigFrame(), isOnScreen: true),
        ]
        let chosen = selectTargetWindow(from: candidates, excludeBundleIDs: ours)
        XCTAssertEqual(chosen?.bundleID, nil)
        XCTAssertNotNil(chosen)
    }
}
#endif
