import Foundation

/// Every time-dependent component takes a Clock so tests run on fixed time.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// A settable clock for tests and `-FengshuiTestMode` scenarios.
public final class FixedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ date: Date) { current = date }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock(); current = date; lock.unlock()
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }
}
