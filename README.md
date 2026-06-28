# Sotto

Нативный macOS-ассистент для разговоров в реальном времени. Слушает микрофон и
системный звук, локально расшифровывает речь, определяет вопросы, подтягивает
персональный контекст и потоком выдаёт подсказки. Всё считается на устройстве —
наружу по умолчанию ничего не отправляется.

Имя — от *sotto voce* («вполголоса»): тихая подсказка на ухо.

## Возможности

- **Захват аудио:** микрофон + системный звук собеседника (`AVAudioEngine`), ресемплинг 16 кГц, VAD.
- **Расшифровка на устройстве:** WhisperKit (Core ML + ANE), потоковые окна (partial → final по паузе).
- **Детект вопросов** в речи собеседника (эвристики).
- **Подсказки:** локальная LLM через MLX (Metal, unified memory), потоковый вывод токенов;
  смена модели в Settings без правки кода.
- **Разбор экрана** (⌥⌘S): OCR выделенной области → подсказка по коду.

Всё считается на устройстве, наружу по умолчанию ничего не уходит. Активная разработка;
доменное ядро (редьюсер состояния, реестр/выбор моделей) покрыто юнит-тестами.

**Внешние зависимости** (только в `SottoWhisper`/`SottoMLX`; `SottoCore` чист):
`argmaxinc/argmax-oss-swift` (WhisperKit), `ml-explore/mlx-swift` + `mlx-swift-lm`,
`huggingface/swift-huggingface` + `swift-transformers`. Первый запуск живой сессии
скачивает выбранные модели (Whisper ~0.6 ГБ + LLM ~2.5 ГБ) с HuggingFace.

**Модели по умолчанию:** Whisper `large-v3-turbo` + LLM `Qwen3-4B-4bit` (под M1/16 ГБ);
переключаются в Settings (есть `small`/`base`, `Qwen3-8B`, `Llama-3.2-3B`).

## Установка (готовая сборка)

Не хочешь собирать сам — скачай приложение из [**Releases**](https://github.com/konstantinsb/Sotto/releases):

1. Скачай `Sotto-<версия>.zip`, распакуй, перетащи **Sotto.app** в `/Applications`.
2. Приложение подписано **ad-hoc** (без платного Apple Developer ID), поэтому при первом
   запуске Gatekeeper попросит подтверждение: правый клик по `Sotto.app` → **Открыть** →
   **Открыть**. Либо разово снять карантин:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Sotto.app
   ```
3. Выдай разрешения в **System Settings → Privacy & Security**: микрофон и запись экрана.
4. Первый запуск живой сессии скачивает модели (~3 ГБ: Whisper + LLM) с HuggingFace —
   интернет нужен один раз.

**Требования:** Apple Silicon (M1+), macOS 15+. Контрольная сумма `SHA-256` — на странице релиза.

## Архитектурные решения (зафиксированы)

- **Движки:** WhisperKit + MLX как дефолт (за протоколами `TranscriptionEngine`,
  `LLMEngine`); нативные Apple-движки (`SpeechAnalyzer`, `Foundation Models`) —
  опциональные бэкенды под `#available(macOS 26)` в будущих фазах.
- **Минимальная macOS:** 15.0 (Sequoia). Тулчейн: Xcode 26 / Swift 6.
- **Проект:** бизнес-логика в локальном SPM-пакете `Core` (`SottoCore`);
  app-оболочка генерируется XcodeGen из `project.yml`.
- **Связь модулей:** только через асинхронные потоки событий (`AsyncStream`),
  изоляция состояния актёрами. Главный поток только рисует.

## Требования

- macOS 15+ (Apple Silicon)
- Xcode 26+
- XcodeGen: `brew install xcodegen`
- Metal Toolchain (для MLX): `xcodebuild -downloadComponent MetalToolchain` (разово, ~0.7 ГБ)

## Сборка и запуск

```bash
# 1. Тесты бизнес-логики (быстро, без Xcode и без MLX/WhisperKit)
cd Core && swift test

# 2. Сгенерировать .xcodeproj из project.yml
cd .. && xcodegen generate

# 3. Открыть в Xcode и запустить (⌘R).
open Sotto.xcodeproj
```

При первом ⌘R Xcode попросит:
- выбрать **Team** в Signing & Capabilities (свой Personal Team, бесплатно);
- **доверить макросы** пакетов MLX («Trust & Enable») — одноразово.

> **Подпись:** `project.yml` использует самоподписанную идентичность `CODE_SIGN_IDENTITY: "Sotto Dev"`
> (стабильная подпись держит TCC-разрешения между пересборками). Если её у тебя нет — перед
> `xcodegen generate` поставь свою: `"-"` для ad-hoc-сборки или свой Personal Team.

Иконка — в строке меню. «Старт встречи» — живая сессия (системный звук собеседника +
WhisperKit + MLX; первый раз скачивает модели). Окно подсказок (оверлей) открывается
автоматически при запуске и держится поверх всего; «Разобрать экран» (⌥⌘S) — кнопка в
панели оверлея; показать/скрыть оверлей — ⌥⌘\. Модели меняются в «Настройки моделей…».

## Структура

```
Sotto/
├── project.yml            # спецификация XcodeGen
├── Core/                  # SPM-пакет SottoCore (домен, протоколы, фейки, оркестратор)
│   ├── Sources/SottoCore/
│   │   ├── Domain/        # Mode, Audio, Transcript, Conversation, SessionEvent
│   │   ├── Audio/         # RingBuffer, AudioCapturing, Fake/MicrophoneCapture, Resampler, Chunker, VAD
│   │   ├── Transcription/ # TranscriptionEngine (+ Fake)
│   │   ├── Detection/     # QuestionDetecting + HeuristicQuestionDetector
│   │   ├── Context/       # ContextProviding (+ Fake)
│   │   ├── LLM/           # LLMEngine, PromptBuilder, SystemPrompts (+ Fake)
│   │   ├── Models/        # ModelRegistry, ModelSelection (реестр + выбор моделей)
│   │   ├── Platform/      # DeviceCapabilities, AppLog, MicrophonePermission
│   │   └── Session/       # SessionConfiguration, SessionActor, ConversationState (редьюсер)
│   ├── Sources/SottoWhisper/  # WhisperKitEngine (Core ML + ANE)
│   ├── Sources/SottoMLX/      # MLXEngine (Metal) — собирается только через Xcode
│   └── Tests/SottoCoreTests/  # юнит-тесты (домен + редьюсер + реестр + сессия/ASR)
├── App/                   # app-таргет (SwiftUI + AppKit)
│   ├── MenuBar/           # MenuBarView
│   ├── FloatingWindow/    # FloatingPanel (NSPanel), контроллер, оверлей
│   └── Settings/          # SettingsView (пикер моделей) + SettingsStore (UserDefaults)
└── Resources/             # Info.plist (usage-строки)
```
