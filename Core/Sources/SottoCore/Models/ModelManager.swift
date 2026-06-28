import Foundation

/// Управление скачанными моделями: путь хранения, размер на диске, удаление,
/// прагматичная авто-перекачка (стереть битое → скачать заново).
///
/// Все модели качаются в наш каталог `modelsDirectory`:
/// — WhisperKit → `<modelsDirectory>/models/argmaxinc/whisperkit-coreml/<variant>`;
/// — MLX (LLM) и embedder → `<modelsDirectory>/hub` (через `HubClient` с нашим `HubCache`).
///
/// `totalSizeBytes`/`deleteAllModels` дополнительно учитывают и чистят прежние
/// расположения (`legacyDirectories`), где модели могли осесть до переноса:
/// `~/Documents/huggingface` (старый WhisperKit) и `~/.cache/huggingface/hub`
/// (дефолт swift-huggingface для MLX/embedder).
public struct ModelManager: Sendable {
    public static let appName = "Sotto"

    /// HF-репозиторий мультиязычного embedder (e5-small). Держим строку здесь, чтобы
    /// точечно чистить его в общем кэше HF; `MLXEmbedder` использует это же значение.
    public static let embedderRepo = "intfloat/multilingual-e5-small"

    /// `~/Library/Application Support/Sotto/Models/` (создаётся при обращении).
    public static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Sotto/Debug/` — отладочные записи сессий (WAV + лог).
    public static var debugDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "Debug", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Наш HuggingFace-кэш для MLX/embedder: `<modelsDirectory>/hub` (создаётся при обращении).
    /// Совпадает с layout `HubCache` (`models--<ns>--<repo>/snapshots/...`).
    public static var huggingFaceCacheDirectory: URL {
        let dir = modelsDirectory.appending(path: "hub", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// HF-репозитории, которые качает Sotto (LLM из реестра + embedder) — для точечной
    /// чистки общего кэша HF, не задевая чужие модели.
    public static var managedHuggingFaceRepos: [String] {
        ModelRegistry.default.llm.map(\.repo) + [embedderRepo]
    }

    /// Папка варианта WhisperKit под нашим downloadBase — для авто-перекачки.
    public static func whisperVariantFolder(variant: String) -> URL {
        modelsDirectory
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: variant, directoryHint: .isDirectory)
    }

    /// Прежний каталог загрузок WhisperKit (swift-transformers): `~/Documents/huggingface`.
    /// Каталог этого класса приложений — чистим целиком.
    public static var legacyDocumentsHFDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: "huggingface", directoryHint: .isDirectory)
    }

    /// Общий кэш HuggingFace (дефолт swift-huggingface на macOS вне песочницы):
    /// `~/.cache/huggingface/hub`. Здесь MLX/embedder лежали до переноса. Кэш общий
    /// (им пользуются и другие инструменты), поэтому чистим только НАШИ репозитории.
    public static var sharedHuggingFaceCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache", directoryHint: .isDirectory)
            .appending(path: "huggingface", directoryHint: .isDirectory)
            .appending(path: "hub", directoryHint: .isDirectory)
    }

    /// Папки наших репозиториев в общем кэше HF (`models--<ns>--<repo>` + парный `.locks/...`).
    private static func sottoRepoDirsInSharedCache() -> [URL] {
        let cache = sharedHuggingFaceCacheDirectory
        return managedHuggingFaceRepos.flatMap { repo -> [URL] in
            let name = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            return [
                cache.appending(path: name, directoryHint: .isDirectory),
                cache.appending(path: ".locks", directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory)
            ]
        }
    }

    /// Суммарный размер скачанных моделей: наш каталог + остатки в прежних расположениях.
    public static func totalSizeBytes() -> Int64 {
        var total = directorySize(modelsDirectory)
        total += directorySize(legacyDocumentsHFDirectory)
        for dir in sottoRepoDirsInSharedCache() { total += directorySize(dir) }
        return total
    }

    /// Удалить все скачанные модели: наш каталог + остатки в прежних расположениях.
    public static func deleteAllModels() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        // Прежний каталог WhisperKit — целиком (он наш по смыслу).
        try? fm.removeItem(at: legacyDocumentsHFDirectory)
        // Общий кэш HF — только наши репозитории, чужие модели не трогаем.
        for dir in sottoRepoDirsInSharedCache() { try? fm.removeItem(at: dir) }
    }

    /// Удалить конкретный вариант WhisperKit (для авто-перекачки).
    public static func deleteWhisperVariant(_ variant: String) {
        try? FileManager.default.removeItem(at: whisperVariantFolder(variant: variant))
    }

    /// Перенести модели из прежних расположений в наш каталог — вместо повторной загрузки.
    /// Вызывать на старте приложения, ДО создания движков. Идемпотентно: перенос (move на
    /// том же томе — мгновенный rename) убирает источник, поэтому повторные запуски — no-op.
    /// Возвращает число перенесённых моделей.
    @discardableResult
    public static func migrateLegacyModels() -> Int {
        let fm = FileManager.default
        var moved = 0

        // 1. HF-репозитории (MLX LLM + embedder): ~/.cache/huggingface/hub → наш hub.
        for repo in managedHuggingFaceRepos {
            let name = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            let src = sharedHuggingFaceCacheDirectory.appending(path: name, directoryHint: .isDirectory)
            let dst = huggingFaceCacheDirectory.appending(path: name, directoryHint: .isDirectory)
            if migrate(from: src, to: dst) { moved += 1 }
            // Парные служебные папки (метаданные/локи) — best-effort.
            for sub in [".metadata", ".locks"] {
                let auxSrc = sharedHuggingFaceCacheDirectory
                    .appending(path: sub, directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory)
                let auxDst = huggingFaceCacheDirectory
                    .appending(path: sub, directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory)
                if fm.fileExists(atPath: auxSrc.path), !fm.fileExists(atPath: auxDst.path) {
                    try? fm.createDirectory(at: auxDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: auxSrc, to: auxDst)
                }
            }
        }

        // 2. WhisperKit-варианты: ~/Documents/huggingface/.../whisperkit-coreml/<variant> → наш models/...
        let legacyWhisperBase = legacyDocumentsHFDirectory
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
        for variant in ModelRegistry.default.asr.map(\.repo) {
            let src = legacyWhisperBase.appending(path: variant, directoryHint: .isDirectory)
            let dst = whisperVariantFolder(variant: variant)
            if migrate(from: src, to: dst) { moved += 1 }
        }

        if moved > 0 { AppLog.session.info("Перенесено моделей из прежних каталогов: \(moved, privacy: .public)") }
        return moved
    }

    /// Перенести каталог src → dst. Переносим, если src существует и полнее dst (по размеру) —
    /// так заменяется частичная/застрявшая докачка целой копией. Возвращает true при переносе.
    private static func migrate(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return false }
        let srcSize = directorySize(src)
        guard srcSize > 0 else { return false }
        if fm.fileExists(atPath: dst.path) {
            guard srcSize > directorySize(dst) else { return false }   // dst уже не хуже — не трогаем
            try? fm.removeItem(at: dst)
        }
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dst)
            return true
        } catch {
            AppLog.session.error("Перенос модели не удался (\(dst.lastPathComponent, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
