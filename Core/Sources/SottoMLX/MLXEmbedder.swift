import Foundation
import SottoCore
@preconcurrency import MLX
@preconcurrency import MLXEmbedders
@preconcurrency import MLXLMCommon
@preconcurrency import MLXHuggingFace
@preconcurrency import HuggingFace
@preconcurrency import Tokenizers

/// Реализация `TextEmbedder` на MLXEmbedders (Metal). Модель по умолчанию —
/// `intfloat/multilingual-e5-small` (мультиязычная, маленькая — комфортна третьей
/// моделью рядом с Whisper+LLM на 16 ГБ).
///
/// ВНИМАНИЕ: таргет компилируется только через Xcode (Metal-шейдеры).
public actor MLXEmbedder: TextEmbedder {
    private let repo: String
    private let onProgress: (@Sendable (DownloadProgress) -> Void)?
    private var container: EmbedderModelContainer?

    public init(
        repo: String = ModelManager.embedderRepo,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) {
        self.repo = repo
        self.onProgress = onProgress
    }

    public func warmUp() async throws {
        try await ensureLoaded()
    }

    public func unload() async {
        container = nil
        Memory.clearCache()
        AppLog.session.info("MLXEmbedder: модель выгружена")
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await ensureLoaded()
        guard let container else { return [] }

        return await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = max(1, encoded.map(\.count).max() ?? 1)
            let batch = encoded.count

            // Паддинг батча до общей длины + attention-маска (1 — токен, 0 — паддинг).
            var tokens: [Int32] = []
            var mask: [Int32] = []
            tokens.reserveCapacity(batch * maxLength)
            mask.reserveCapacity(batch * maxLength)
            for ids in encoded {
                for id in ids { tokens.append(Int32(id)); mask.append(1) }
                for _ in ids.count..<maxLength { tokens.append(0); mask.append(0) }
            }

            let inputArray = MLXArray(tokens).reshaped([batch, maxLength])
            let maskArray = MLXArray(mask).reshaped([batch, maxLength])
            let tokenTypes = MLXArray([Int32](repeating: 0, count: batch * maxLength))
                .reshaped([batch, maxLength])

            let output = context.model(
                inputArray, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: maskArray
            )
            let pooled = context.pooling(output, mask: maskArray, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }

    private func ensureLoaded() async throws {
        guard container == nil else { return }
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
        let onProgress = self.onProgress
        // Загрузчик «сначала локально»: при наличии модели — без сети (наш каталог).
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: HuggingFaceDownload.cachedFirstDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: repo),
            progressHandler: { progress in onProgress?(DownloadProgress(progress)) }
        )
        AppLog.session.info("MLXEmbedder загружен: \(self.repo, privacy: .public)")
    }
}
