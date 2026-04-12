import Foundation

/// Thread-safe ring buffer for inter-module data passing (roadmap F-016).
public final class RingBuffer<T> {
    private var buffer: [T?]
    private let capacity: Int
    private var head: Int = 0
    private var tail: Int = 0
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [T?](repeating: nil, count: capacity)
    }

    public func push(_ element: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let next = (tail + 1) % capacity
        if next == head { return false }
        buffer[tail] = element
        tail = next
        return true
    }

    public func pop() -> T? {
        lock.lock()
        defer { lock.unlock() }
        if head == tail { return nil }
        let v = buffer[head]
        buffer[head] = nil
        head = (head + 1) % capacity
        return v
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return head == tail
    }
}
