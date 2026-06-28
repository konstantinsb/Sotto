import Foundation

/// Запись базы знаний: типовой вопрос собеседования + канонический каркас ответа.
public struct QAEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var topic: String
    public var question: String
    public var answer: String

    public init(id: UUID = UUID(), topic: String, question: String, answer: String) {
        self.id = id
        self.topic = topic
        self.question = question
        self.answer = answer
    }

    /// Текст для индексации и сниппета: вопрос помогает матчингу запроса, ответ — полезное
    /// содержимое, которое подмешивается в промпт.
    public var indexedText: String { "Вопрос: \(question)\nОтвет: \(answer)" }
}

/// База типовых вопросов/ответов — доп. источник RAG рядом с профилем. Под входящий вопрос
/// достаются 1–3 ближайшие записи и подмешиваются как опорные тезисы (модель опирается на
/// канонический ответ, а не сочиняет с нуля). Редактируется в приложении (фаза UI).
public struct QACorpus: Sendable, Codable, Equatable {
    public var entries: [QAEntry]

    public init(entries: [QAEntry] = []) {
        self.entries = entries
    }

    public static let empty = QACorpus()
    public var isEmpty: Bool { entries.isEmpty }

    /// Источники для чанкования: (заголовок, текст) на каждую запись (как `UserProfile.sources`).
    public var sources: [(title: String, text: String)] {
        entries.map { (title: "Q&A: \($0.topic)", text: $0.indexedText) }
    }

    /// Корпус под режим: технические интервью получают iOS-базу, остальные — пусто.
    public static func forMode(_ mode: ModeKind) -> QACorpus {
        switch mode {
        case .iosInterview, .systemDesignInterview, .behavioralInterview:
            return .iosDefault
        default:
            return .empty
        }
    }

    /// Стартовый iOS/Swift-корпус — по темам реального собеседования (Structures/Classes, ARC,
    /// Hashing, COW, Optionals, Dispatching, Concurrency, GCD, SwiftUI).
    public static let iosDefault = QACorpus(entries: [
        QAEntry(topic: "Value vs reference",
                question: "В чём разница value и reference семантики, когда struct, когда class?",
                answer: "Value (struct, enum) копируется при передаче — у каждого своя копия; reference (class) передаёт ссылку на один объект. По умолчанию struct: проще, потокобезопаснее, без ARC-накладных. Class — когда нужна общая идентичность, наследование или мутация общего состояния."),
        QAEntry(topic: "Память value/reference",
                question: "Где в памяти хранятся value и reference типы?",
                answer: "Reference-объекты — в куче, переменная держит ссылку. Value-типы обычно в стеке или инлайн внутри владельца, но уезжают в кучу при захвате замыканием, в existential-боксах, при большом размере или внутри reference-типа."),
        QAEntry(topic: "ARC и виды ссылок",
                question: "Что такое ARC и какие бывают ссылки?",
                answer: "ARC считает сильные ссылки и освобождает объект, когда их 0. strong удерживает; weak не удерживает и обнуляется в nil (Optional, через side table); unowned не удерживает и не обнуляется (краш при доступе после освобождения), но быстрее weak."),
        QAEntry(topic: "Retain cycle",
                question: "Что такое цикл сильных ссылок и как его разорвать?",
                answer: "Два объекта держат друг друга strong → счётчик не падает до 0 → утечка (минимум два объекта и две сильные ссылки). Разрыв: одну ссылку сделать weak или unowned, в замыканиях — список захвата [weak self]/[unowned self]."),
        QAEntry(topic: "Hashable и коллизии",
                question: "Что такое коллизии и как работает Hashable?",
                answer: "Коллизия — разные значения попадают в один бакет; разрешается цепочками/пробированием. Hashable требует hash(into:) и ==; равные значения обязаны давать равный хэш. Для своих типов комбинируй значимые поля; неравный хэш у равных — баг."),
        QAEntry(topic: "Copy-on-write",
                question: "Что такое copy-on-write и как написать самому?",
                answer: "Коллекции делят буфер до первой мутации; при записи, если буфер не уникален (isKnownUniquelyReferenced), делается копия. Поэтому копия массива не аллоцирует, пока её не изменишь. Свой COW — обернуть reference-storage в struct и копировать в mutating при неуникальной ссылке. reserveCapacity избегает переаллокаций."),
        QAEntry(topic: "Optionals",
                question: "Что такое Optional?",
                answer: "Optional<T> — enum с .some(T)/.none: «значение или его отсутствие». Разворот через if let/guard let/??/optional chaining; force unwrap (!) крашит на nil."),
        QAEntry(topic: "Диспетчеризация",
                question: "Какие типы диспетчеризации и что быстрее, что такое witness/virtual table?",
                answer: "Static (direct) — самый быстрый, известно на компиляции (final, struct-методы, static). Table-based: virtual table (классы/наследование) и witness table (методы протокола). Dynamic (@objc/dynamic) — через runtime, самый медленный. final/struct → статическая."),
        QAEntry(topic: "Контекст исполнителя",
                question: "Что такое контекст исполнителя в Swift Concurrency?",
                answer: "Executor, на котором идёт код: actor исполняет свой код на своём сериализованном executor; @MainActor — на главном; неизолированный async — на глобальном concurrent executor. Конкретный тред не гарантируется — важна изоляция, а не номер треда."),
        QAEntry(topic: "Отмена Task",
                question: "Как реагировать на отмену таски?",
                answer: "Отмена кооперативная: проверяй Task.isCancelled или вызывай try Task.checkCancellation() — сам код она не останавливает. cancel() ставит флаг; в обработчике освобождай ресурсы и выходи раньше."),
        QAEntry(topic: "detached Task",
                question: "Чем detached таска отличается от обычной и зачем она?",
                answer: "Обычная Task наследует приоритет, actor-изоляцию и task-local из контекста; Task.detached не наследует ничего (свой приоритет, без изоляции). Нужна редко — когда явно надо оторваться от контекста; обычно лучше структурированная Task."),
        QAEntry(topic: "GCD vs Concurrency",
                question: "Чем GCD отличается от async/await и почему их опасно мешать?",
                answer: "GCD — очереди и замыкания, ручное управление тредами, легко словить гонки/ад колбэков. Swift Concurrency — async/await + actors, структурно, компилятор проверяет изоляцию (data race safety), приоритеты и отмена встроены. Мешать осторожно — у них разные модели тредов и пул."),
        QAEntry(topic: "State/StateObject/ObservedObject",
                question: "Разница @State, @StateObject и @ObservedObject?",
                answer: "@State — value-состояние, которым владеет сам View. @StateObject — View владеет reference-моделью, создаётся один раз и переживает перерисовки. @ObservedObject — View не владеет, модель приходит снаружи; если создавать её тут, она пересоздаётся при перерисовке (отсюда сброс счётчика) — лечится переносом во владельца как @StateObject."),
        QAEntry(topic: "@Observable",
                question: "Что такое @Observable и чем лучше ObservableObject?",
                answer: "@Observable (Observation framework, макрос на этапе компиляции) даёт точечное наблюдение: обновляются только View, реально читавшие изменившееся свойство. ObservableObject шлёт общий objectWillChange и обновляет всё, что зависит от объекта. Владение всё равно через @State/@StateObject."),
        QAEntry(topic: "recompute body",
                question: "Чем перерасчёт body отличается от перерисовки экрана и плохо ли это?",
                answer: "body — вычисление нового описания View-графа (должно быть чистым и дешёвым). SwiftUI диффает новый граф со старым по структуре/identity и применяет минимальные изменения к рендеру, а не рисует заново. Частый пересчёт body нормален; проблема — тяжёлые вычисления, сайд-эффекты или неустойчивая identity внутри.")
    ])
}
