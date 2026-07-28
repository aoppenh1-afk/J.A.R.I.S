import Foundation
import XCTest
@testable import JarvisCore

final class ParakeetModelCacheValidatorTests: XCTestCase {
    func testAcceptsCompleteCacheLayout() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for relativePath in ParakeetModelCacheValidator.requiredRelativePaths {
            let fileURL = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data([0]))
        }

        XCTAssertNoThrow(try ParakeetModelCacheValidator.validate(at: root))
    }

    func testReportsEveryMissingCacheAsset() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try ParakeetModelCacheValidator.validate(at: root)) { error in
            guard case .incomplete(let rootPath, let missingPaths) = error as? ParakeetModelCacheError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rootPath, root.path)
            XCTAssertEqual(missingPaths, ParakeetModelCacheValidator.requiredRelativePaths)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-model-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
