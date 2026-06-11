import XCTest
import IntatisCore
@testable import IntatisArtifacts

final class IntatisArtifactsTests: XCTestCase {

    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-artifacts-\(UUID().uuidString)", isDirectory: true)
    }

    func testAddReadAndPersistAcrossReload() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(name: "note.txt",
                                                data: Data("hello".utf8),
                                                mime: "text/plain")
        XCTAssertEqual(ref.kind, .fileAttachment)
        XCTAssertTrue(ref.path.hasPrefix("blobs/"))

        let data = try await store.data(for: ref.id)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")

        // Reload from disk: index must have been persisted.
        let reloaded = try ArtifactStore(root: root)
        let all = await reloaded.list()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, ref.id)
        let again = try await reloaded.data(for: ref.id)
        XCTAssertEqual(String(decoding: again, as: UTF8.self), "hello")
    }

    func testMissingArtifactThrows() async {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try ArtifactStore(root: root)
            _ = try await store.data(for: ArtifactID(rawValue: "art_missing"))
            XCTFail("expected notFound")
        } catch {
            // expected
        }
    }
}
