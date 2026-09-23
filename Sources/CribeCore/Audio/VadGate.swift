import FluidAudio
import Foundation

/// Поверхность VAD, на которую опирается `DictationController`: вердикт по готовой записи
/// и стрим для автостопа.
///
/// Протокол нужен ровно затем же, зачем `AudioCapturing` и `TranscriptionEngine`: конвейер
/// не должен знать, кто выносит вердикт, а тесты подставляют заглушку вместо CoreML-модели —
/// иначе прогон тянул бы её из сети на чистой машине.
public protocol SpeechGating: Sendable {
    /// Обрезает тишину по краям записи. `nil` — речи нет.
    func trimmed(_ samples: [Float]) async throws -> [Float]?

    /// Путь совместимости с Handy для Whisper: НЕ нормализует амплитуду, вырезает длинные
    /// неречевые интервалы и сохраняет pre-roll/hangover вокруг каждой речевой области.
    func handyWhisperFiltered(_ samples: [Float]) async throws -> [Float]?

    /// Сбрасывает состояние стрима перед новой записью и фиксирует её порог тишины.
    func resetStream(silenceDuration: TimeInterval) async
    /// Скармливает чанк записи. `true` — пора останавливаться по тишине.
    func feedStream(_ chunk: [Float]) async throws -> Bool
}

public extension SpeechGating {
    /// Тестовые/альтернативные гейты автоматически получают безопасный fallback.
    /// Настоящий VadGate переопределяет его Handy-подобным speech-only путём.
    func handyWhisperFiltered(_ samples: [Float]) async throws -> [Float]? {
        try await trimmed(samples)
    }
}

/// Silero VAD через FluidAudio (CoreML/ANE): настраиваемый автостоп по тишине в стриме
/// и обрезка тишины по краям готовой записи.
/// Модель (~2 МБ) скачивается лениво при первом создании гейта.
public actor VadGate: SpeechGating {

    /// Отсечка коротких записей — 0.5 c (защита от галлюцинаций и prompt-leak).
    private static let minSpeechSamples = VadManager.sampleRate / 2

    private let vad: VadManager
    /// Конфигурация принадлежит конкретной записи и меняется только вместе со сбросом
    /// её stream-state. Значение ниже — безопасный стартовый дефолт до первого reset.
    private var streamConfig = VadSegmentationConfig(minSilenceDuration: 2.0)
    private var streamState = VadStreamState.initial()
    /// Цепочка вызовов feedStream: актор реентерабелен, а `streamState` — read-modify-write.
    private var inFlight: Task<Bool, Error>?
    /// Номер записи: результат, посчитанный до `resetStream()`, выбрасывается.
    private var generation = 0

    public init() async throws {
        vad = try await VadManager(config: VadConfig())
    }

    /// Обрезает тишину по краям записи. `nil`, если речи нет или её меньше 0.5 c.
    public func trimmed(_ samples: [Float]) async throws -> [Float]? {
        guard samples.count >= Self.minSpeechSamples else { return nil }
        let segments = try await vad.segmentSpeech(samples, config: .default)
        guard let first = segments.first, let last = segments.last else { return nil }

        let rate = VadManager.sampleRate
        let start = max(0, min(first.startSample(sampleRate: rate), samples.count))
        let end = max(start, min(last.endSample(sampleRate: rate), samples.count))
        let speech = Array(samples[start..<end])
        guard speech.count >= Self.minSpeechSamples else { return nil }
        return speech
    }

    /// Batch-VAD профиль для Whisper, повторяющий ключевые параметры Handy:
    /// threshold 0.30, ~450 мс pre-roll и ~450 мс post-speech tail, длинная внутренняя
    /// тишина вырезается. FluidAudio считает VAD крупнее по времени (256 мс чанки), поэтому
    /// это функциональная, а не побитовая копия Rust/Silero пути Handy.
    public func handyWhisperFiltered(_ samples: [Float]) async throws -> [Float]? {
        guard samples.count >= Self.minSpeechSamples else { return nil }

        // negativeThreshold + offset определяют и entry threshold в FluidAudio.
        // 0.30 + 0.00 => тот же threshold, который Handy задаёт Silero VAD.
        let config = VadSegmentationConfig(
            minSpeechDuration: 0.06,
            minSilenceDuration: 0.45,
            maxSpeechDuration: .infinity,
            speechPadding: 0,
            silenceThresholdForSplit: 0.30,
            negativeThreshold: 0.30,
            negativeThresholdOffset: 0,
            minSilenceAtMaxSpeech: 0.098,
            useMaxPossibleSilenceAtMaxSpeech: true
        )
        let segments = try await vad.segmentSpeech(samples, config: config)
        guard !segments.isEmpty else { return nil }

        let rate = VadManager.sampleRate
        let padding = Int(0.45 * Double(rate))
        var ranges: [(start: Int, end: Int)] = []
        ranges.reserveCapacity(segments.count)

        for segment in segments {
            let rawStart = segment.startSample(sampleRate: rate)
            let rawEnd = segment.endSample(sampleRate: rate)
            let start = max(0, min(rawStart - padding, samples.count))
            let end = max(start, min(rawEnd + padding, samples.count))
            guard end > start else { continue }

            if let last = ranges.indices.last, start <= ranges[last].end {
                ranges[last].end = max(ranges[last].end, end)
            } else {
                ranges.append((start, end))
            }
        }

        guard !ranges.isEmpty else { return nil }
        let capacity = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        var speech: [Float] = []
        speech.reserveCapacity(capacity)
        for range in ranges {
            speech.append(contentsOf: samples[range.start..<range.end])
        }

        guard speech.count >= Self.minSpeechSamples else { return nil }
        return speech
    }

    /// Сбрасывает состояние стрима перед новой записью. Длительность тишины фиксируется
    /// здесь, поэтому изменение настройки посреди диктовки начинает действовать со следующей.
    public func resetStream(silenceDuration: TimeInterval) {
        generation += 1
        streamConfig = VadSegmentationConfig(minSilenceDuration: max(0.1, silenceDuration))
        streamState = VadStreamState.initial()
    }

    /// Скармливает чанк (4096 сэмплов 16 кГц). `true` — настроенная пауза тишины
    /// после речи закончилась, пора останавливаться.
    /// Вызовы выстраиваются в очередь, чтобы состояние стрима обновлялось строго по порядку.
    public func feedStream(_ chunk: [Float]) async throws -> Bool {
        // Поколение фиксируем в момент постановки в очередь, а не в начале счёта: чанк,
        // вставший в очередь до `resetStream()`, доходит до `process` уже после него
        // и иначе засеял бы новую запись звуком предыдущей.
        let queuedGeneration = generation
        let previous = inFlight
        let task = Task { [self] in
            _ = try? await previous?.value
            return try await process(chunk, generation: queuedGeneration)
        }
        inFlight = task
        return try await task.value
    }

    private func process(_ chunk: [Float], generation queued: Int) async throws -> Bool {
        // Пока чанк стоял в очереди, могла начаться новая запись — он уже не про неё.
        guard queued == generation else { return false }
        let result = try await vad.processStreamingChunk(chunk, state: streamState, config: streamConfig)
        // И то же самое после счёта: `processStreamingChunk` — точка приостановки.
        guard queued == generation else { return false }
        streamState = result.state
        return result.event?.isEnd == true
    }
}
