import Combine
import CryptoKit
import Foundation
import CribeCore

/// Единый реестр локальных ASR-моделей.
///
/// Старое имя `ModelInstall` сохранено намеренно: онбординг и настройки уже завязаны
/// на этот долгоживущий объект. Он обслуживает Parakeet, GigaAM и импортированные
/// transcribe.cpp-модели (GGUF и совместимые legacy Whisper .bin).
@MainActor
final class ModelInstall: ObservableObject {
    enum State: Equatable {
        case missing
        /// Доля скачанного, 0...1. Для встроенных загрузок Cribe показывает реальный
        /// прогресс; 0 допустим только до первого callback от транспортного слоя.
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    struct ModelEntry: Identifiable, Equatable {
        let id: String
        let displayName: String
        let detail: String
        let approximateBytes: Int64?
        let removable: Bool
        let imported: Bool
    }

    enum LibraryError: LocalizedError {
        case checksumMismatch
        case activeModelCannotBeRemoved
        case unknownModel
        case modelNotReady
        case unsupportedImportFormat

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return "Контрольная сумма скачанной GigaAM не совпала. Файл удалён."
            case .activeModelCannotBeRemoved:
                return "Нельзя удалить единственную готовую модель распознавания."
            case .unknownModel:
                return "Модель больше не найдена в реестре."
            case .modelNotReady:
                return "Сначала модель нужно скачать или импортировать."
            case .unsupportedImportFormat:
                return "Поддерживаются модели .gguf и совместимые legacy Whisper .bin."
            }
        }
    }

    private struct ImportedModel: Codable, Equatable, Identifiable {
        let id: String
        let displayName: String
        let filename: String
        let architecture: String
        let variant: String
        let languages: [String]
        let sizeBytes: Int64
        /// Старые registry.json этого поля не имеют; nil трактуется как GGUF.
        let format: String?
    }

    static let shared = ModelInstall(settings: .shared)

    /// Размер Parakeet нужен старому онбордингу/окну миграции.
    static let approximateBytes: Int64 = 600 * 1_000_000

    static let gigaAMBytes: Int64 = 273_724_832
    static let gigaAMSHA256 = "78d63b47723b7f8d78c6113a6ef983b5a86e2a86f6c273e1f5cb6967b1c4467a"
    static let gigaAMURL = URL(
        string: "https://huggingface.co/handy-computer/gigaam-v3-e2e-rnnt-gguf/resolve/main/gigaam-v3-e2e-rnnt-Q8_0.gguf"
    )!

    /// Совместимость со старым UI: это состояние именно Parakeet.
    @Published private(set) var state: State
    @Published private var modelStates: [String: State] = [:]
    @Published private var importedModels: [ImportedModel] = []
    @Published private var revision = 0

    private let settings: AppSettings
    private let rootURL: URL
    private let importedURL: URL
    private let manifestURL: URL
    private let gigaAMFileURL: URL

    private var tasks: [String: Task<Void, Never>] = [:]

    /// Единственная сильная ссылка менеджера на прогретый active engine. При переключении
    /// она снимается; старый engine живёт только у уже начатых DictationSession и после их
    /// завершения освобождает RAM/Metal через ARC.
    private var cachedEngineID: String?
    private var cachedEngine: TranscriptionEngine?

    init(settings: AppSettings, rootURL: URL? = nil) {
        self.settings = settings
        let root = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Cribe", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

        self.rootURL = root
        importedURL = root.appendingPathComponent("imported", isDirectory: true)
        manifestURL = root.appendingPathComponent("registry.json")
        gigaAMFileURL = root.appendingPathComponent("gigaam-v3-e2e-rnnt-Q8_0.gguf")

        state = ParakeetEngine.isInstalled ? .ready : .missing

        do {
            try FileManager.default.createDirectory(
                at: importedURL,
                withIntermediateDirectories: true
            )
            if let data = try? Data(contentsOf: manifestURL) {
                importedModels = try JSONDecoder().decode([ImportedModel].self, from: data)
            }
        } catch {
            importedModels = []
        }

        modelStates[ASRModelID.parakeet] = state
        modelStates[ASRModelID.gigaAME2ERNNTQ8] =
            FileManager.default.fileExists(atPath: gigaAMFileURL.path) ? .ready : .missing

        for model in importedModels {
            modelStates[model.id] = FileManager.default.fileExists(
                atPath: importedURL.appendingPathComponent(model.filename).path
            ) ? .ready : .failed("Файл модели не найден.")
        }

        normalizeActiveSelection()
    }

    var isReady: Bool { state == .ready }

    var hasAnyReadyModel: Bool {
        entries.contains { state(for: $0.id) == .ready }
    }

    var activeModelID: String { settings.activeASRModelID }

    var entries: [ModelEntry] {
        var result = [
            ModelEntry(
                id: ASRModelID.parakeet,
                displayName: "Parakeet TDT v3",
                detail: "Многоязычная · FluidAudio",
                approximateBytes: Self.approximateBytes,
                removable: false,
                imported: false
            ),
            ModelEntry(
                id: ASRModelID.gigaAME2ERNNTQ8,
                displayName: "GigaAM v3 E2E-RNN-T Q8_0",
                detail: "Русский · GGUF · transcribe.cpp",
                approximateBytes: Self.gigaAMBytes,
                removable: true,
                imported: false
            ),
        ]

        result.append(contentsOf: importedModels.map { model in
            var pieces = [model.architecture]
            if !model.variant.isEmpty { pieces.append(model.variant) }
            if !model.languages.isEmpty { pieces.append(model.languages.joined(separator: ", ")) }
            pieces.append(model.format ?? "GGUF")
            return ModelEntry(
                id: model.id,
                displayName: model.displayName,
                detail: pieces.filter { !$0.isEmpty }.joined(separator: " · "),
                approximateBytes: model.sizeBytes,
                removable: true,
                imported: true
            )
        })
        return result
    }

    func state(for id: String) -> State {
        modelStates[id] ?? .missing
    }

    func isActive(_ id: String) -> Bool {
        settings.activeASRModelID == id
    }

    /// Есть ли на диске выбранная модель. Прогрев тут не делаем.
    var activeModelIsInstalled: Bool {
        switch settings.activeASRModelID {
        case ASRModelID.parakeet:
            return ParakeetEngine.isInstalled
        case ASRModelID.gigaAME2ERNNTQ8:
            return FileManager.default.fileExists(atPath: gigaAMFileURL.path)
        default:
            guard let model = importedModels.first(where: { $0.id == settings.activeASRModelID }) else {
                return false
            }
            return FileManager.default.fileExists(
                atPath: importedURL.appendingPathComponent(model.filename).path
            )
        }
    }

    /// Engine для НОВОЙ диктовки. Контроллер снимет эту ссылку в DictationSession.
    func activeEngine() -> TranscriptionEngine {
        normalizeActiveSelection()
        let id = settings.activeASRModelID

        // Никаких скрытых скачиваний на первой диктовке.
        guard activeModelIsInstalled else {
            return MissingLocalModelEngine()
        }

        if cachedEngineID == id, let cachedEngine {
            return cachedEngine
        }

        let engine: TranscriptionEngine
        switch id {
        case ASRModelID.parakeet:
            engine = ParakeetEngine()
        default:
            guard let url = modelURL(for: id) else {
                settings.activeASRModelID = ASRModelID.parakeet
                revision &+= 1
                let fallback = ParakeetEngine()
                cachedEngineID = ASRModelID.parakeet
                cachedEngine = fallback
                return fallback
            }
            engine = TranscribeCppEngine(modelURL: url)
        }

        cachedEngineID = id
        cachedEngine = engine
        return engine
    }

    func activate(_ id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { throw LibraryError.unknownModel }
        guard state(for: id) == .ready else { throw LibraryError.modelNotReady }
        guard settings.activeASRModelID != id else { return }

        settings.activeASRModelID = id
        cachedEngineID = nil
        cachedEngine = nil
        revision &+= 1
    }

    /// Перечитать диск. Текущую загрузку/подготовку не затираем.
    func refresh() {
        if tasks[ASRModelID.parakeet] == nil {
            setState(ParakeetEngine.isInstalled ? .ready : .missing, for: ASRModelID.parakeet)
        }
        if tasks[ASRModelID.gigaAME2ERNNTQ8] == nil {
            setState(
                FileManager.default.fileExists(atPath: gigaAMFileURL.path) ? .ready : .missing,
                for: ASRModelID.gigaAME2ERNNTQ8
            )
        }
        for model in importedModels where tasks[model.id] == nil {
            let exists = FileManager.default.fileExists(
                atPath: importedURL.appendingPathComponent(model.filename).path
            )
            setState(exists ? .ready : .failed("Файл модели не найден."), for: model.id)
        }
        normalizeActiveSelection()
    }

    /// Старый вход онбординга/ModelUpdateView: скачать именно Parakeet.
    func download() {
        download(ASRModelID.parakeet)
    }

    func download(_ id: String) {
        guard tasks[id] == nil else { return }

        switch id {
        case ASRModelID.parakeet:
            downloadParakeet()
        case ASRModelID.gigaAME2ERNNTQ8:
            downloadGigaAM()
        default:
            break
        }
    }

    private func downloadParakeet() {
        let id = ASRModelID.parakeet
        guard state(for: id) != .ready else { return }

        setState(ParakeetEngine.isInstalled ? .preparing : .downloading(0), for: id)
        let engine: ParakeetEngine
        if cachedEngineID == id, let cached = cachedEngine as? ParakeetEngine {
            engine = cached
        } else {
            engine = ParakeetEngine()
        }

        tasks[id] = Task { [weak self, engine] in
            guard let self else { return }
            do {
                try await engine.prepare(language: settings.language) { [weak self] asr in
                    Task { @MainActor in self?.applyParakeet(asr) }
                }
                if settings.activeASRModelID == id {
                    cachedEngineID = id
                    cachedEngine = engine
                }
                setState(.ready, for: id)
            } catch {
                setState(.failed(error.localizedDescription), for: id)
            }
            tasks[id] = nil
        }
    }

    private func downloadGigaAM() {
        let id = ASRModelID.gigaAME2ERNNTQ8
        guard state(for: id) != .ready else { return }

        setState(.downloading(0), for: id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            let staging = rootURL.appendingPathComponent(".gigaam-download-" + UUID().uuidString + ".gguf")
            defer { try? FileManager.default.removeItem(at: staging) }

            do {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                let downloader = ProgressFileDownloader(
                    expectedBytes: Self.gigaAMBytes,
                    progress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.setState(.downloading(fraction), for: id)
                        }
                    }
                )
                try await downloader.download(from: Self.gigaAMURL, to: staging)

                setState(.preparing, for: id)
                let digest = try await Task.detached(priority: .utility) {
                    try modelFileSHA256(staging)
                }.value
                guard digest == Self.gigaAMSHA256 else { throw LibraryError.checksumMismatch }

                _ = try await Task.detached(priority: .userInitiated) {
                    try TranscribeCppEngine.inspectModel(at: staging)
                }.value

                try? FileManager.default.removeItem(at: gigaAMFileURL)
                try FileManager.default.moveItem(at: staging, to: gigaAMFileURL)
                setState(.ready, for: id)
                if !activeModelIsInstalled {
                    try? activate(id)
                }
            } catch {
                setState(.failed(error.localizedDescription), for: id)
            }
            tasks[id] = nil
        }
    }

    /// Импорт GGUF и legacy Whisper .bin через тот же transcribe.cpp runtime.
    @discardableResult
    func importModel(from source: URL) async throws -> String {
        try FileManager.default.createDirectory(at: importedURL, withIntermediateDirectories: true)

        let sourceExtension = source.pathExtension.lowercased()
        guard sourceExtension == "gguf" || sourceExtension == "bin" else {
            throw LibraryError.unsupportedImportFormat
        }

        let token = UUID().uuidString.lowercased()
        let id = "model-" + token
        let filename = token + "." + sourceExtension
        let staging = rootURL.appendingPathComponent(".import-" + token + "." + sourceExtension)
        let destination = importedURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)

        do {
            let info = try await Task.detached(priority: .userInitiated) {
                try TranscribeCppEngine.inspectModel(at: staging)
            }.value
            let size = try Self.fileSize(at: staging)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)

            let record = ImportedModel(
                id: id,
                displayName: source.deletingPathExtension().lastPathComponent,
                filename: filename,
                architecture: info.architecture,
                variant: info.variant,
                languages: info.languages,
                sizeBytes: size,
                format: sourceExtension == "bin" ? "Whisper BIN" : "GGUF"
            )
            importedModels.append(record)
            do {
                try saveManifest()
            } catch {
                importedModels.removeAll { $0.id == id }
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            setState(.ready, for: id)
            if !activeModelIsInstalled {
                try? activate(id)
            }
            return id
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    @discardableResult
    func importGGUF(from source: URL) async throws -> String {
        try await importModel(from: source)
    }

    func removeModel(_ id: String) throws {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw LibraryError.unknownModel
        }
        guard entry.removable else { return }

        if settings.activeASRModelID == id {
            guard let fallback = fallbackModel(excluding: id) else {
                throw LibraryError.activeModelCannotBeRemoved
            }
            try activate(fallback)
        }

        if id == ASRModelID.gigaAME2ERNNTQ8 {
            try? FileManager.default.removeItem(at: gigaAMFileURL)
            setState(.missing, for: id)
            return
        }

        guard let imported = importedModels.first(where: { $0.id == id }) else {
            throw LibraryError.unknownModel
        }
        try? FileManager.default.removeItem(
            at: importedURL.appendingPathComponent(imported.filename)
        )
        importedModels.removeAll { $0.id == id }
        modelStates.removeValue(forKey: id)
        try saveManifest()
    }

    private func fallbackModel(excluding id: String) -> String? {
        if id != ASRModelID.parakeet, state(for: ASRModelID.parakeet) == .ready {
            return ASRModelID.parakeet
        }
        return entries.first { $0.id != id && state(for: $0.id) == .ready }?.id
    }

    private func normalizeActiveSelection() {
        let id = settings.activeASRModelID
        guard id != ASRModelID.parakeet else { return }

        guard entries.contains(where: { $0.id == id }), state(for: id) == .ready else {
            settings.activeASRModelID = ASRModelID.parakeet
            cachedEngineID = nil
            cachedEngine = nil
            revision &+= 1
            return
        }
    }

    private func modelURL(for id: String) -> URL? {
        if id == ASRModelID.gigaAME2ERNNTQ8 {
            return FileManager.default.fileExists(atPath: gigaAMFileURL.path)
                ? gigaAMFileURL : nil
        }
        guard let model = importedModels.first(where: { $0.id == id }) else { return nil }
        let url = importedURL.appendingPathComponent(model.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func setState(_ newState: State, for id: String) {
        modelStates[id] = newState
        if id == ASRModelID.parakeet { state = newState }
    }

    private func applyParakeet(_ asr: ASRModelState) {
        switch asr {
        case .downloading(let fraction):
            setState(.downloading(fraction), for: ASRModelID.parakeet)
        case .loading:
            setState(.preparing, for: ASRModelID.parakeet)
        case .ready:
            setState(.ready, for: ASRModelID.parakeet)
        case .notLoaded:
            break
        }
    }

    private func saveManifest() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(importedModels)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

}

private final class MissingLocalModelEngine: TranscriptionEngine {
    private struct NoModelError: LocalizedError {
        var errorDescription: String? {
            "Сначала выберите и установите модель распознавания в Настройки → Общие."
        }
    }

    func prepare(
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        onState(.notLoaded)
        throw NoModelError()
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        throw NoModelError()
    }
}

private final class ProgressFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private var destination: URL?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var fileError: Error?

    init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func download(from url: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.destination = destination
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let denominator = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard denominator > 0 else { return }
        progress(min(1, max(0, Double(totalBytesWritten) / Double(denominator))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else {
            fileError = URLError(.cannotCreateFile)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fileError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            self.destination = nil
            self.continuation = nil
        }

        if let error {
            continuation?.resume(throwing: error)
        } else if let fileError {
            continuation?.resume(throwing: fileError)
        } else if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse))
        } else {
            progress(1)
            continuation?.resume()
        }
    }
}

private func modelFileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
