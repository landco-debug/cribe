import Foundation
import OSLog
import TranscribeCpp

/// Универсальный backend для ASR-моделей GGUF, которые понимает transcribe.cpp.
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

    private let modelURL: URL
    private let lock = NSLock()
    private var model: Model?
    private var loading: Task<Model, Error>?

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    /// Полная проверка GGUF до регистрации в Cribe.
    ///
    /// Загружаем модель тем же runtime, которым потом будем распознавать. Поэтому файл с
    /// корректным расширением, но неизвестной ASR-архитектурой, не сможет попасть в реестр.
    public static func inspectModel(at url: URL) throws -> ModelInfo {
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
        let options = RunOptions(
            task: .transcribe,
            timestamps: .none,
            language: language.rawValue
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
        let options = RunOptions(
            task: .translate,
            timestamps: .none,
            language: language.rawValue,
            targetLanguage: "en"
        )
        let result = try await session.run(samples, options: options)
        return result.text
    }

    private func ready() async throws -> Model {
        if let loaded = locked({ model }) { return loaded }

        let task: Task<Model, Error> = locked {
            if let loading { return loading }
            let url = modelURL
            let started = Task.detached(priority: .userInitiated) {
                try Model(path: url.path, options: ModelOptions(backend: .auto))
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
                "GGUF готов: \(loaded.arch, privacy: .public) / \(loaded.variant, privacy: .public), backend=\(loaded.backend, privacy: .public)"
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
