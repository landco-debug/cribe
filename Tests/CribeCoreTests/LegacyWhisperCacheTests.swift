import Foundation
import XCTest
@testable import CribeCore

final class LegacyWhisperCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyWhisperCacheTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCurrentASRModelsAreNotCountedAsLegacyAndSurviveCleanup() throws {
        let imported = root.appendingPathComponent("imported/current.bin")
        let giga = root.appendingPathComponent("gigaam-v3-e2e-rnnt-Q8_0.gguf")
        let registry = root.appendingPathComponent("registry.json")
        let staging = root.appendingPathComponent(".gigaam-download-test.gguf")
        let legacy = root.appendingPathComponent("old-whisper/weights.mlmodelc/weight.bin")

        try write(Data(repeating: 1, count: 32 * 1024), to: imported)
        try write(Data(repeating: 2, count: 24 * 1024), to: giga)
        try write(Data("[]".utf8), to: registry)
        try write(Data(repeating: 3, count: 8 * 1024), to: staging)
        try write(Data(repeating: 4, count: 4 * 1024), to: legacy)

        let cache = LegacyWhisperCache(base: root)
        XCTAssertTrue(cache.exists())
        XCTAssertGreaterThan(cache.bytesOnDisk(), 0)

        try cache.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: giga.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: registry.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(cache.exists())
        XCTAssertEqual(cache.bytesOnDisk(), 0)
    }

    func testTopLevelBinAndGGUFAreProtectedEvenIfRegistryDoesNotKnowThemYet() throws {
        let bin = root.appendingPathComponent("manual.bin")
        let gguf = root.appendingPathComponent("manual.gguf")
        try write(Data(repeating: 1, count: 1024), to: bin)
        try write(Data(repeating: 2, count: 1024), to: gguf)

        let cache = LegacyWhisperCache(base: root)
        XCTAssertFalse(cache.exists())
        XCTAssertEqual(cache.bytesOnDisk(), 0)

        try cache.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gguf.path))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
