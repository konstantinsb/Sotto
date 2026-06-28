import Foundation
import SottoCore
@preconcurrency import HuggingFace
@preconcurrency import MLXLMCommon
@preconcurrency import MLXHuggingFace

/// Загрузка моделей HuggingFace для MLX в наш каталог.
///
/// `cachedFirstDownloader` сперва пробует локальный кэш **без сети** (`localFilesOnly`),
/// и только если модели нет — качает. Так наличие модели не приводит к сетевым
/// проверкам ETag на HuggingFace, которые могут зависать.
enum HuggingFaceDownload {
    /// HubClient, который кладёт/ищет модели в нашем каталоге (`.../Sotto/Models/hub`).
    static func hubClient() -> HubClient {
        HubClient(cache: HubCache(cacheDirectory: ModelManager.huggingFaceCacheDirectory))
    }

    static func cachedFirstDownloader() -> any MLXLMCommon.Downloader {
        CachedFirstDownloader(hub: hubClient())
    }
}

private struct CachedFirstDownloader: MLXLMCommon.Downloader {
    let hub: HubClient

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw HuggingFaceDownloaderError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"

        // 1. Уже в кэше? — отдаём мгновенно, без обращения к сети.
        if !useLatest,
           let cached = try? await hub.downloadSnapshot(
                of: repoID, revision: revision, matching: patterns, localFilesOnly: true) {
            return cached
        }

        // 2. Иначе — обычная загрузка с прогрессом.
        return try await hub.downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}
