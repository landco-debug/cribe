import Foundation
import XCTest
@testable import Cribe
import CribeCore

@MainActor
final class ModelInstallTests: XCTestCase {
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() {
        super.setUp()
        let suite = "ModelInstallTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cribe-ModelInstallTests-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        defaults = nil
        root = nil
        super.tearDown()
    }

    func testBuiltInRegistryContainsParakeetAndGigaAM() {
        let install = ModelInstall(settings: AppSettings(defaults: defaults), rootURL: root)
        XCTAssertEqual(
            install.entries.map(\.id),
            [ASRModelID.parakeet, ASRModelID.gigaAME2ERNNTQ8]
        )
        XCTAssertEqual(install.state(for: ASRModelID.gigaAME2ERNNTQ8), .missing)
    }

    func testMissingPersistedGGUFFallsBackToParakeet() {
        let settings = AppSettings(defaults: defaults)
        settings.activeASRModelID = ASRModelID.gigaAME2ERNNTQ8

        let install = ModelInstall(settings: settings, rootURL: root)

        XCTAssertEqual(install.activeModelID, ASRModelID.parakeet)
        XCTAssertEqual(settings.activeASRModelID, ASRModelID.parakeet)
    }

    func testInvalidGGUFIsNotRegistered() async throws {
        let install = ModelInstall(settings: AppSettings(defaults: defaults), rootURL: root)
        let invalid = root.deletingLastPathComponent()
            .appendingPathComponent("invalid-" + UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: invalid) }
        try Data("not a supported ASR GGUF".utf8).write(to: invalid)

        do {
            _ = try await install.importGGUF(from: invalid)
            XCTFail("Невалидный GGUF не должен регистрироваться")
        } catch {
            XCTAssertEqual(install.entries.count, 2)
        }
    }
}
