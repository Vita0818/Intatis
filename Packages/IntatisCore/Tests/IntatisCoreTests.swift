import XCTest
@testable import IntatisCore

final class IntatisCoreTests: XCTestCase {

    func testProfilePresets() {
        XCTAssertFalse(PlatformProfile.macAppStore.allowsShell)
        XCTAssertTrue(PlatformProfile.macDeveloperID.allowsShell)
        XCTAssertFalse(PlatformProfile.iOS.allowsWorkspace)
        XCTAssertEqual(PlatformProfile.iOS.surfaces, [.chat])
        XCTAssertTrue(PlatformProfile.macAppStore.supports(.cowork))
        XCTAssertFalse(PlatformProfile.iOS.supports(.code))
    }

    func testIDCodesAsBareString() throws {
        let id = SessionID(rawValue: "sess_test")
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"sess_test\"")
        let back = try JSONDecoder().decode(SessionID.self, from: data)
        XCTAssertEqual(back, id)
    }

    func testIDGenPrefixAndUniqueness() {
        XCTAssertTrue(SessionID.new().rawValue.hasPrefix("sess_"))
        XCTAssertNotEqual(MessageID.new(), MessageID.new())
    }

    func testSessionKindWorkspace() {
        XCTAssertFalse(SessionKind.chat.usesWorkspace)
        XCTAssertTrue(SessionKind.code.usesWorkspace)
        XCTAssertTrue(SessionKind.cowork.usesWorkspace)
    }
}
