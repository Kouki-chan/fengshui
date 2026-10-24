import FengshuiKit
import Foundation
import WatchConnectivity

/// Phone side of the watch channel. Behind a protocol so tests use an in-process
/// fake (simulator WatchConnectivity file transfer is unreliable; TEST_STRATEGY.md).
protocol WatchLink: Sendable {
    /// Mirror recording preferences to the watch (updateApplicationContext).
    func push(prefs: RecordingPreferences) throws
    /// Acknowledge an imported file (transferUserInfo {"ack": fileID}).
    func acknowledge(fileID: String)
    var isReachable: Bool { get }
    var isPaired: Bool { get }
}

final class WCPhoneLink: NSObject, WatchLink, WCSessionDelegate, @unchecked Sendable {
    private let importer: WatchImporter
    private let log: EventLog
    private let afterImport: @Sendable () async -> Void

    init(importer: WatchImporter, log: EventLog, afterImport: @escaping @Sendable () async -> Void) {
        self.importer = importer
        self.log = log
        self.afterImport = afterImport
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var isReachable: Bool { WCSession.isSupported() && WCSession.default.isReachable }
    var isPaired: Bool { WCSession.isSupported() && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled }

    func push(prefs: RecordingPreferences) throws {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try WCSession.default.updateApplicationContext(prefs.asContext())
    }

    func acknowledge(fileID: String) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo(["ack": fileID])
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this method returns: copy it first, import async.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fsc")
        do { try FileManager.default.copyItem(at: file.fileURL, to: tmp) } catch {
            log.add("watch_file_error", "\(error)")
            return
        }
        Task { [importer, log, afterImport] in
            do {
                let r = try await importer.importFile(tmp)
                log.add("watch_import", "\(r.chunks) chunks")
                self.acknowledge(fileID: r.fileID)
                await afterImport()
            } catch {
                log.add("watch_import_error", "\(error)")
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        log.add("wc_activated", "\(state.rawValue) \(error.map { "\($0)" } ?? "")")
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}

/// In-process stand-in: test-mode and unit tests.
final class FakeWatchLink: WatchLink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var pushed: [RecordingPreferences] = []
    private(set) var acks: [String] = []
    var isReachable = true
    var isPaired = true

    func push(prefs: RecordingPreferences) throws { lock.withLock { pushed.append(prefs) } }
    func acknowledge(fileID: String) { lock.withLock { acks.append(fileID) } }
}
