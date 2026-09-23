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


    /// Семантика запуска зависит от семейства.
    ///
    /// Для Whisper НЕ отключаем timestamps: AUTO у transcribe.cpp выбирает segment path,
    /// на котором реализованы long-form chunking/temperature fallback. Прежнее .none
    /// насильно уводило Whisper на упрощённый decode path.
    ///
    /// Если runtime сообщает, что это Whisper, передаём также словарный prompt и включаем
    /// previous-token context между 30-секундными чанками. Для GigaAM и остальных семейств
    /// family=nil, AUTO разрешается самим runtime в поддерживаемую гранулярность (обычно NONE).
    private func runOptions(
        model: Model,
        task: TranscriptionTask,
        language: Language,
        prompt: String,
        targetLanguage: String? = nil
    ) -> RunOptions {
        var family: RunExtension?
        let whisperProbe = RunExtension.whisper(WhisperRunOptions())
        if model.accepts(whisperProbe) {
            family = .whisper(
                WhisperRunOptions(
                    initialPrompt: prompt.isEmpty ? nil : prompt,
                    conditionOnPrevTokens: true
                )
            )
        }

        return RunOptions(
            task: task,
            timestamps: .auto,
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
