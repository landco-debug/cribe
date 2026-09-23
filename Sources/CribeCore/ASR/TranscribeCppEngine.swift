import Darwin
import Foundation
import OSLog
import TranscribeCpp

/// Универсальный backend для ASR-моделей, которые понимает transcribe.cpp:
/// GGUF и legacy Whisper .bin (runtime определяет формат по содержимому файла).
///
/// Модель задаётся путём к файлу. Сам runtime определяет архитектуру из GGUF и
/// отвергает неподдерживаемые architecture/variant.
public final class TranscribeCppEngine: TranscriptionEngine, @unchecked Sendable {
    public struct ModelInfo: Sendable, Equatable {
        public let architecture: String
        public let variant: String
        public let languages: [String]
        public let nativeSampleRate: Int32
        public let backend: String

        public init(
            architecture: String,
            variant: String,
            languages: [String],
            nativeSampleRate: Int32,
            backend: String
        ) {
            self.architecture = architecture
            self.variant = variant
            self.languages = languages
            self.nativeSampleRate = nativeSampleRate
            self.backend = backend
        }
    }

    public enum EngineError: LocalizedError {
        case incompatibleSampleRate(Int32)

        public var errorDescription: String? {
            switch self {
            case let .incompatibleSampleRate(rate):
                return "Модель использует частоту \(rate) Гц, а Cribe передаёт 16 кГц PCM."
            }
        }
    }

    private static let logger = Logger(
        subsystem: "online.nazarovych.cribe",
        category: "TranscribeCpp"
    )

    /// ggml из transcribe.cpp v0.2.3 на macOS 15+ может abort() при штатном выходе,
    /// если Metal residency sets включены: device destructor видит незакрытые rsets.
    /// В самом vendored ggml предусмотрен этот официальный escape hatch. Он отключает
    /// только residency-set keep-alive, а НЕ Metal backend/GPU.
    private static let configureGGMLMetalOnce: Void = {
        _ = setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
    }()

    private static func configureRuntime() {
        _ = configureGGMLMetalOnce
    }

    private let modelURL: URL
    private let lock = NSLock()
    private var model: Model?
    private var loading: Task<Model, Error>?

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    /// После prepare архитектура уже известна из реально загруженной модели.
    /// Handy подаёт Whisper исходную амплитуду и VAD-filtered speech, поэтому именно
    /// whisper-family получает отдельный профиль. GigaAM и остальные transcribe.cpp
    /// семейства сохраняют прежний вход Cribe.
    public var audioInputProfile: ASRAudioInputProfile {
        let architecture = locked { model?.arch.lowercased() }
        return architecture == "whisper" ? .handyWhisper : .standard
    }

    /// Полная проверка модели до регистрации в Cribe.
    ///
    /// Загружаем модель тем же runtime, которым потом будем распознавать. Поэтому файл с
    /// корректным расширением, но неизвестной ASR-архитектурой, не сможет попасть в реестр.
    public static func inspectModel(at url: URL) throws -> ModelInfo {
        configureRuntime()
        let model = try Model(path: url.path, options: ModelOptions(backend: .cpu))
        let capabilities = model.capabilities
        if capabilities.nativeSampleRate != 0, capabilities.nativeSampleRate != 16_000 {
            throw EngineError.incompatibleSampleRate(capabilities.nativeSampleRate)
        }
        return ModelInfo(
            architecture: model.arch,
            variant: model.variant,
            languages: capabilities.languages,
            nativeSampleRate: capabilities.nativeSampleRate,
            backend: model.backend
        )
    }

    public func prepare(
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        if locked({ model != nil }) {
            onState(.ready)
            return
        }
        onState(.loading)
        do {
            _ = try await ready()
            onState(.ready)
        } catch {
            onState(.notLoaded)
            throw error
        }
    }

    public func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String
    ) async throws -> String {
        let model = try await ready()
        let session = try model.session()
        let options = runOptions(
            model: model,
            task: .transcribe,
            language: language,
            prompt: prompt
        )
        let result = try await session.run(samples, options: options)
        return result.text
    }

    public func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String {
        guard translating else {
            return try await transcribe(samples, language: language, prompt: prompt)
        }

        let model = try await ready()
        guard model.capabilities.supportsTranslate else {
            throw TranscriptionEngineError.translationUnsupported
        }
        let session = try model.session()
        let options = runOptions(
            model: model,
            task: .translate,
            language: language,
            prompt: prompt,
            targetLanguage: "en"
        )
        let result = try await session.run(samples, options: options)
        return result.text
    }


    /// Параметры run повторяют актуальный Handy для transcribe.cpp:
    /// все общие knobs остаются library defaults, а Whisper family-extension создаётся
    /// ТОЛЬКО когда есть реальный initial prompt. Пустая подсказка не должна сама по себе
    /// менять decode recipe.
    ///
    /// В частности, не форсируем `conditionOnPrevTokens`: shipping default
    /// transcribe.cpp v0.2.3 — false, и Handy оставляет его таким же.
    private func runOptions(
        model: Model,
        task: TranscriptionTask,
        language: Language,
        prompt: String,
        targetLanguage: String? = nil
    ) -> RunOptions {
        var family: RunExtension?
        if !prompt.isEmpty {
            let whisper = RunExtension.whisper(
                WhisperRunOptions(initialPrompt: prompt)
            )
            if model.accepts(whisper) {
                family = whisper
            }
        }

        return RunOptions(
            task: task,
            language: language.rawValue,
            targetLanguage: targetLanguage,
            family: family
        )
    }

    private func ready() async throws -> Model {
        if let loaded = locked({ model }) { return loaded }

        let task: Task<Model, Error> = locked {
            if let loading { return loading }
            let url = modelURL
            let started = Task.detached(priority: .userInitiated) {
                Self.configureRuntime()
                return try Model(path: url.path, options: ModelOptions(backend: .auto))
            }
            loading = started
            return started
        }

        do {
            let loaded = try await task.value
            locked {
                model = loaded
                loading = nil
            }
            Self.logger.notice(
                "ASR-модель готова: \(self.modelURL.lastPathComponent, privacy: .public), \(loaded.arch, privacy: .public) / \(loaded.variant, privacy: .public), backend=\(loaded.backend, privacy: .public)"
            )
            return loaded
        } catch {
            locked { loading = nil }
            throw error
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
