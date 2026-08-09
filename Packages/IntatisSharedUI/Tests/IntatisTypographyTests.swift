#if canImport(SwiftUI)
import XCTest
@testable import IntatisSharedUI

final class IntatisTypographyTests: XCTestCase {
    func testSharedTypographyRolesKeepTheCrossPlatformDesignContract() {
        let expected: [IntatisTypographyRole: IntatisTypographySpec] = [
            .brand: IntatisTypographySpec(
                nominalPointSize: 28,
                weight: .semibold,
                design: .serif),
            .largeTitle: IntatisTypographySpec(
                nominalPointSize: 30,
                weight: .semibold,
                design: .serif),
            .title: IntatisTypographySpec(
                nominalPointSize: 20,
                weight: .semibold,
                design: .serif),
            .headline: IntatisTypographySpec(
                nominalPointSize: 16,
                weight: .semibold,
                design: .sansSerif),
            .body: IntatisTypographySpec(
                nominalPointSize: 14,
                weight: .regular,
                design: .sansSerif),
            .caption: IntatisTypographySpec(
                nominalPointSize: 12,
                weight: .medium,
                design: .sansSerif),
            .metadata: IntatisTypographySpec(
                nominalPointSize: 10,
                weight: .medium,
                design: .sansSerif),
            .monospaced: IntatisTypographySpec(
                nominalPointSize: 13,
                weight: .regular,
                design: .monospaced),
            .chat: IntatisTypographySpec(
                nominalPointSize: 15,
                weight: .regular,
                design: .sansSerif),
        ]

        XCTAssertEqual(Set(expected.keys), Set(IntatisTypographyRole.allCases))
        for role in IntatisTypographyRole.allCases {
            XCTAssertEqual(IntatisTypography.spec(for: role), expected[role])
        }
    }
}
#endif
