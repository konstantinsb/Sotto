import XCTest
import CryptoKit
@testable import SottoCore

final class CryptoBoxTests: XCTestCase {
    func testRoundTripString() {
        let box = CryptoBox(key: SymmetricKey(size: .bits256))
        let secret = "Чувствительный транскрипт: пароль 1234, ARC и акторы."
        let cipher = box.encrypt(secret)
        XCTAssertNotNil(cipher)
        XCTAssertNotEqual(cipher, secret.data(using: .utf8))  // реально зашифровано
        XCTAssertEqual(box.decryptString(cipher!), secret)
    }

    func testWrongKeyFailsToDecrypt() {
        let cipher = CryptoBox(key: SymmetricKey(size: .bits256)).encrypt("секрет")!
        let other = CryptoBox(key: SymmetricKey(size: .bits256))
        XCTAssertNil(other.decryptString(cipher))   // другой ключ — не расшифровать
    }

    func testRoundTripData() {
        let box = CryptoBox(key: SymmetricKey(size: .bits256))
        let data = Data((0..<256).map { UInt8($0 % 256) })
        let cipher = box.encrypt(data)!
        XCTAssertEqual(box.decryptData(cipher), data)
    }
}
