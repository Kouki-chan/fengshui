import Foundation

/// HealthKit background delivery for the six spec types (§6.1), plus the fallback:
/// the same incremental sync runs on launch, foreground and BGAppRefreshTask, because
/// background delivery on a Personal Team is unconfirmed until the device test (§1a).
final class BackgroundDelivery: Sendable {
    private let sync: HealthSync
    private let store: HealthStore
    private let afterSync: @Sendable (_ trigger: String) async -> Void
    let log: EventLog

    init(sync: HealthSync, store: HealthStore, log: EventLog,
         afterSync: @escaping @Sendable (_ trigger: String) async -> Void) {
        self.sync = sync
        self.store = store
        self.log = log
        self.afterSync = afterSync
    }

    /// Register observer queries. Must run on every launch (HealthKit relaunches the app
    /// in the background and expects the observers to be re-created before it returns).
    func register() async {
        for id in HealthTypeCatalog.backgroundDelivery {
            guard let t = HealthTypeCatalog.info(id) else { continue }
            do {
                try await store.observe(t) { [sync, afterSync, log] in
                    log.add("bg_delivery", t.label)
                    do {
                        let n = try await sync.sync(t)
                        log.add("bg_sync", "\(t.label) +\(n)")
                    } catch {
                        log.add("bg_sync_error", "\(t.label): \(error)")
                    }
                    await afterSync("healthkit:\(t.label)")
                }
                log.add("bg_registered", t.label)
            } catch {
                log.add("bg_register_error", "\(t.label): \(error)")
            }
        }
    }

    /// Fallback path: launch, foreground, BGAppRefreshTask.
    func syncNow(trigger: String) async {
        do {
            let n = try await sync.syncAll()
            log.add("sync", "\(trigger) +\(n)")
        } catch {
            log.add("sync_error", "\(trigger): \(error)")
        }
        await afterSync(trigger)
    }
}

/// A small in-memory ring buffer of app events, shown in the debug screen and
/// included in Diagnostics (Phase 8). Never contains health values.
final class EventLog: @unchecked Sendable {
    struct Event: Identifiable, Sendable {
        let id = UUID()
        let ts: Date
        let kind: String
        let detail: String
    }

    private let lock = NSLock()
    private var items: [Event] = []
    private let capacity: Int
    private let clock: @Sendable () -> Date

    init(capacity: Int = 500, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = capacity
        self.clock = clock
    }

    func add(_ kind: String, _ detail: String = "") {
        lock.lock()
        items.append(Event(ts: clock(), kind: kind, detail: detail))
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        lock.unlock()
    }

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func count(_ kind: String) -> Int { events.filter { $0.kind == kind }.count }
}
