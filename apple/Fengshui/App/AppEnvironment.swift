import FengshuiKit
import Foundation

/// Dependency container. Real Apple frameworks in normal runs; fakes loaded with a
/// named scenario when launched with `-FengshuiTestMode <scenario>` (spec §14.1),
/// so UI tests never hit permission dialogs.
final class AppEnvironment: Sendable {
    let db: AppDatabase
    let clock: Clock
    let health: HealthStore
    let healthSync: HealthSync
    let delivery: BackgroundDelivery
    let location: LocationProvider
    let places: PlaceService
    let motion: MotionImporter
    let watchImporter: WatchImporter
    let watchLink: WatchLink
    let engine: EngineRunner
    let notifications: NotificationCenter
    let windDown: WindDownScheduler
    let secrets: SecretStore
    let server: ServerSync
    let questions: AIQuestionStore
    let inbox: InboxStore
    let reports: ReportStore
    let monitor: MonitorClient
    let log: EventLog
    let testScenario: String?
    let timeZone: TimeZone

    init(db: AppDatabase, clock: Clock, health: HealthStore, location: LocationProvider, motion: MotionHistory,
         watchLink makeLink: (WatchImporter, EventLog, EngineRunner) -> WatchLink,
         notifications: NotificationCenter, secrets: SecretStore, network: NetworkStatus,
         testScenario: String?, timeZone: TimeZone, reportsDirectory: URL? = nil) {
        self.db = db
        self.clock = clock
        self.health = health
        self.location = location
        self.testScenario = testScenario
        self.timeZone = timeZone
        let log = EventLog(clock: { [clock] in clock.now })
        self.log = log
        let sync = HealthSync(db: db, store: health, clock: clock)
        healthSync = sync
        let motionImporter = MotionImporter(db: db, history: motion, clock: clock)
        self.motion = motionImporter
        self.notifications = notifications
        let windDown = WindDownScheduler(db: db, center: notifications, clock: clock, timeZone: timeZone, log: log)
        self.windDown = windDown
        // Every engine run may have written or superseded a plan → (re)schedule (spec §11).
        self.secrets = secrets
        let server = ServerSync(db: db, secrets: secrets, network: network, clock: clock, log: log,
                                deviceID: Self.deviceID(db))
        self.server = server
        let engine = EngineRunner(db: db, clock: clock, timeZone: timeZone, log: log, server: server,
                                  afterRun: { _ in await windDown.sync() })
        self.engine = engine
        questions = AIQuestionStore(db: db, clock: clock)
        try? questions.seedIfNeeded()
        let inbox = InboxStore(db: db, clock: clock, center: notifications)
        self.inbox = inbox
        reports = ReportStore(db: db, clock: clock, timeZone: timeZone, inbox: inbox,
                              directory: reportsDirectory ?? ReportStore.defaultDirectory())
        monitor = MonitorClient(db: db, server: server, clock: clock, inbox: inbox, notifications: notifications, log: log,
                                deviceID: Self.deviceID(db), liveSync: { await Self.syncLiveTypes(sync, log: log) })
        places = PlaceService(db: db, location: location, log: log, clock: clock,
                              onHomeArrival: { ts in
                                  await engine.run(EngineRunner.lightTasks, trigger: "home_arrival")
                                  await windDown.homeArrival(at: ts)
                              },
                              onVisit: { await engine.run(EngineRunner.lightTasks, trigger: "visit") })
        let importer = WatchImporter(db: db, clock: clock)
        watchImporter = importer
        watchLink = makeLink(importer, log, engine)
        delivery = BackgroundDelivery(sync: sync, store: health, log: log) { trigger in
            // Every sync also pulls iPhone motion history (spec §6.3).
            do {
                let n = try await motionImporter.importNew()
                log.add("motion", "\(trigger) +\(n)")
            } catch {
                log.add("motion_error", "\(error)")
            }
            // Spec §9: light tasks for refresh-type wakes, everything otherwise.
            let light = trigger == "bg_refresh" || trigger.hasPrefix("healthkit:")
            await engine.run(light ? EngineRunner.lightTasks : EngineRunner.allTasks, trigger: trigger)
            // Nightly processing also archives old raw chunks and syncs to the Mac (spec §9, §12).
            if trigger == "bg_processing" || trigger == "manual_sync" {
                do {
                    try await server.archive()
                    try await server.sync()
                } catch { log.add("server_error", "\(error)") }
            }
        }
    }

    var isTestMode: Bool { testScenario != nil }

    // MARK: Claude (spec §13)

    var claudeModel: String {
        ((try? db.preference(ClaudeAssistant.modelKey, as: String.self)) ?? nil) ?? ClaudeAssistant.defaultModel
    }

    /// Pulls the fast-changing HealthKit types now (Data tab, monitor checks). Skipped until the
    /// onboarding backfill finishes, so it never races the backfill's anchors.
    static func syncLiveTypes(_ sync: HealthSync, log: EventLog) async {
        guard (try? await sync.backfillDone()) == true else { return }
        for id in DataSnapshot.liveTypes {
            guard let t = HealthTypeCatalog.info(id) else { continue }
            do {
                let n = try await sync.sync(t)
                if n > 0 { log.add("live_sync", "\(t.label) +\(n)") }
            } catch {
                log.add("live_sync_error", "\(t.label): \(error)")
            }
        }
    }

    func syncLiveTypes() async { await Self.syncLiveTypes(healthSync, log: log) }

    /// nil until an API key is entered in Settings (Keychain). Report tools are always available;
    /// the Report tab passes its own actions to pin the user's filter.
    func assistant(transport: MessagesTransport? = nil, actions: AssistantActions? = nil) -> ClaudeAssistant? {
        let t: MessagesTransport
        if let transport { t = transport } else {
            guard let key = secrets.get(SecretKey.anthropicKey), !key.isEmpty else { return nil }
            t = AnthropicHTTP(apiKey: key)
        }
        guard let tools = try? ClaudeTools(dbPath: db.path, timeZone: timeZone) else { return nil }
        return ClaudeAssistant(db: db, tools: tools, transport: t, clock: clock, timeZone: timeZone, model: claudeModel,
                               actions: actions ?? ReportActions(store: reports))
    }

    var scheduledQuestions: ScheduledQuestions {
        ScheduledQuestions(store: questions, assistant: { [self] in assistant() }, notifications: notifications,
                           timeZone: timeZone)
    }

    /// A random id for this install, used by the server's devices table.
    static func deviceID(_ db: AppDatabase) -> String {
        if let id = (try? db.preference("device_id", as: String.self)) ?? nil { return id }
        let id = UUID().uuidString
        try? db.setPreference("device_id", id)
        return id
    }

    // MARK: Recording preferences (spec §7.2)

    func recordingPreferences() -> RecordingPreferences {
        ((try? db.preference(RecordingPreferences.key, as: RecordingPreferences.self)) ?? RecordingPreferences()).sanitized()
    }

    func saveRecordingPreferences(_ p: RecordingPreferences) {
        let clean = p.sanitized()
        try? db.setPreference(RecordingPreferences.key, clean, now: clock.now)
        do { try watchLink.push(prefs: clean) } catch { log.add("watch_prefs_error", "\(error)") }
    }

    /// Builds the environment for this process from its launch arguments.
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> AppEnvironment {
        if let i = arguments.firstIndex(of: "-FengshuiTestMode"), i + 1 < arguments.count {
            let name = arguments[i + 1]
            let scenario = try Scenario.load(name)
            // Fresh DB per launch: UI tests start from a known state.
            let db = try AppDatabase.temporary("testmode-\(name)")
            let home = scenario.places.first { $0.kind == "home" }
            return AppEnvironment(db: db, clock: FixedClock(Date(timeIntervalSince1970: scenario.now)),
                                  health: FakeHealthStore(scenario: scenario),
                                  location: FakeLocationProvider(coordinate: (home?.lat ?? 40.1, home?.lon ?? -75.2)),
                                  motion: FakeMotionHistory(scenario: scenario), watchLink: { _, _, _ in FakeWatchLink() },
                                  // -FengshuiRealNotifications: the permission-granting UI test uses the real center.
                                  notifications: arguments.contains("-FengshuiRealNotifications")
                                      ? SystemNotificationCenter() : FakeNotificationCenter(),
                                  secrets: MemorySecretStore(), network: FixedNetworkStatus(onWiFi: true),
                                  testScenario: name,
                                  timeZone: TimeZone(identifier: scenario.tz) ?? .current)
        }
        return AppEnvironment(db: try AppDatabase(path: AppDatabase.defaultURL().path), clock: SystemClock(),
                              health: HKHealthStoreAdapter(), location: CoreLocationProvider(),
                              motion: CoreMotionHistory(),
                              watchLink: { importer, log, engine in
                                  WCPhoneLink(importer: importer, log: log, afterImport: {
                                      await engine.run(["features", "activity", "wind_down"], trigger: "watch_import")
                                  })
                              },
                              notifications: SystemNotificationCenter(), secrets: KeychainStore(),
                              network: PathNetworkStatus(), testScenario: nil, timeZone: .current)
    }
}
