import OSLog

/// Тонкая обёртка над `os.Logger`. Принцип: в логи НЕ попадает содержимое разговоров —
/// только структурные события и метрики задержки.
public enum AppLog {
    public static let subsystem = "com.konstantin.sotto"

    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let llm = Logger(subsystem: subsystem, category: "llm")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
