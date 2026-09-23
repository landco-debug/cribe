import AVFoundation
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
    
    /// В обычном CI тест ничего не скачивает. Отдельный smoke-workflow подставляет
    /// официальный Q8_0 и короткий русский fixture transcribe.cpp и проходит полный run.
    @Test("Реальная GigaAM Q8_0 распознаёт русский fixture")
    func realGigaAMSmoke() async throws {
        guard
            let modelPath = ProcessInfo.processInfo.environment["TRANSCRIBE_GIGAAM_GGUF"],
            let wavPath = ProcessInfo.processInfo.environment["TRANSCRIBE_GIGAAM_WAV"]
        else { return }

        let modelURL = URL(fileURLWithPath: modelPath)
        let info = try TranscribeCppEngine.inspectModel(at: modelURL)
        #expect(info.architecture.lowercased().contains("gigaam"))
        #expect(info.nativeSampleRate == 16_000)

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            Issue.record("Не удалось создать PCM-буфер fixture")
            return
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            Issue.record("Fixture не удалось получить как Float32 PCM")
            return
        }
        let samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )

        let engine = TranscribeCppEngine(modelURL: modelURL)
        try await engine.prepare(language: .ru) { _ in }
        let text = try await engine.transcribe(samples, language: .ru, prompt: "")
        #expect(text == "Важно различать глаголы и дополнения.")
    }
}
