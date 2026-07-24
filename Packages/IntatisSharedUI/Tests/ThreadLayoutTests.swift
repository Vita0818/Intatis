#if os(macOS)
import XCTest
@testable import IntatisSharedUI

final class ThreadLayoutTests: XCTestCase {
    func testLeadingAssistantAndAgentRowsUseTheFullAvailableWidth() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: false,
                fillsAvailableWidth: true,
                maxWidth: 560,
                gutter: 48),
            .fullWidthLeading)
    }

    func testTrailingUserRowsKeepTheirBubbleWidthAndLeadingGutter() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: true,
                fillsAvailableWidth: false,
                maxWidth: 560,
                gutter: 48),
            .constrained(isTrailing: true, maxWidth: 560, gutter: 48))
    }

    func testOtherLeadingRowsKeepTheirExistingConstrainedLayout() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: false,
                fillsAvailableWidth: false,
                maxWidth: 560,
                gutter: 48),
            .constrained(isTrailing: false, maxWidth: 560, gutter: 48))
    }
}
#endif
