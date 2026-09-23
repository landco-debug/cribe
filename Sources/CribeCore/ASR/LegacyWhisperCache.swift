import Foundation

/// Остатки старого WhisperKit/ModelStore в общей папке моделей.
///
/// Исторически весь `~/Library/Application Support/Cribe/models` принадлежал старым
/// Whisper-весам, поэтому прежняя реализация считала и удаляла папку целиком. После
/// появления GigaAM и импортируемых GGUF/BIN этот каталог стал общим: удалять его целиком
/// больше нельзя.
///
/// Текущие управляемые файлы Cribe защищены явным safelist. Всё остальное на верхнем
/// уровне считается legacy-кандидатом. Это сохраняет старую возможность освободить место,
/// но никогда не трогает активные GigaAM/импортированные модели.
public struct LegacyWhisperCache: Sendable {
    public static let shared = LegacyWhisperCache(base: defaultBase)

    public static let defaultBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cribe", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// Сколько занимают ТОЛЬКО legacy-кандидаты.
    public func bytesOnDisk() -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]

        var total: Int64 = 0
        for root in legacyTopLevelEntries() {
            if let values = try? root.resourceValues(forKeys: keys),
               values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                continue
            }

            guard let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys)
            ) else { continue }

            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    public func exists() -> Bool {
        !legacyTopLevelEntries().isEmpty
    }

    /// Удаляет только legacy-кандидаты, сохраняя текущий registry и все современные модели.
    public func remove() throws {
        for url in legacyTopLevelEntries() {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func legacyTopLevelEntries() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.filter { !Self.isCurrentManagedEntry($0) }
    }

    private static func isCurrentManagedEntry(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // ModelInstall: imported models + manifest.
        if name == "imported" || name == "registry.json" {
            return true
        }

        // Встроенная GigaAM и её временный staging во время загрузки.
        if name == "gigaam-v3-e2e-rnnt-Q8_0.gguf" || name.hasPrefix(".gigaam-download-") {
            return true
        }

        // Безопасность на будущее/ручные файлы: современный ASR-файл верхнего уровня
        // нельзя объявлять «старым мусором» только потому, что его ещё не знает этот код.
        if ext == "gguf" || ext == "bin" {
            return true
        }

        return false
    }
}
