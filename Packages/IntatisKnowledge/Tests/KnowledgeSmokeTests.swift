import XCTest
@testable import IntatisKnowledge

final class KnowledgeSmokeTests: XCTestCase {
    func testContractVersionIsPinned() {
        XCTAssertEqual(KnowledgeContract.profileVersion, "0.1")
    }
}
