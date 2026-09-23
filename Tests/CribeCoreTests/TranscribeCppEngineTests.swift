import Foundation
import Testing
@testable import CribeCore

@Suite("TranscribeCppEngine")
struct TranscribeCppEngineTests {
    @Test("Невалидный GGUF не проходит импортную проверку")
    func invalidGGUFIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("not-a-model.gguf")
        try Data("definitely not a GGUF model".utf8).write(to: file)

        #expect(throws: Error.self) {
            _ = try TranscribeCppEngine.inspectModel(at: file)
        }
    }
}
