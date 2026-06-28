import Foundation

/// Потокобезопасный кольцевой буфер с перезаписью самых старых элементов при переполнении.
///
/// Контракт под аудио-конвейер: производитель (захват) пишет и НЕ ждёт; потребитель
/// (обработка) читает в своём темпе. При отставании потребителя устаревшие элементы
/// сбрасываются (backpressure), а не копятся бесконечно — счётчик `dropped` это фиксирует.
public final class RingBuffer<Element>: @unchecked Sendable {
    private var storage: [Element?]
    private let capacity: Int
    private var head = 0        // индекс следующей записи
    private var available = 0   // элементов доступно для чтения
    private var droppedCount = 0
    private let lock = NSLock()

    public init(capacity: Int) {
        precondition(capacity > 0, "ёмкость кольцевого буфера должна быть положительной")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Записать элемент. При переполнении перезаписывает самый старый непрочитанный.
    public func write(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        storage[head] = element
        head = (head + 1) % capacity
        if available == capacity {
            droppedCount += 1   // перезаписали ещё не прочитанный элемент
        } else {
            available += 1
        }
    }

    /// Прочитать самый старый элемент (FIFO) либо `nil`, если буфер пуст.
    public func read() -> Element? {
        lock.lock(); defer { lock.unlock() }
        guard available > 0 else { return nil }
        let tail = (head - available + capacity) % capacity
        let value = storage[tail]
        storage[tail] = nil
        available -= 1
        return value
    }

    /// Сколько элементов сейчас доступно для чтения.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return available
    }

    /// Сколько элементов было сброшено из-за переполнения за всё время.
    public var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }
}
