import FengshuiKit
import Foundation
import GRDB
import UIKit

/// Settings → Diagnostics (spec §14.1): self-checks on the real device, uploaded as JSON to
/// the Mac server (`POST /diagnostics`) so they can be read during the device test.
/// Contains counts, times and pass/fail — never health values, tokens or keys.
struct Diagnostics: Sendable {
    struct Check: Codable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Report: Codable, Sendable {
        var generatedAt: Double
        var appVersion: String
        var device: String
        var systemVersion: String
        var timeZone: String
        var checks: [Check]
        var metrics: [String: Double]
    }

    let env: AppEnvironment

    func run() async -> Report {
        var checks: [Check] = []
        var metrics: [String: Double] = [:]
        let now = env.clock.now.timeIntervalSince1970
        let db = env.db

        // HealthKit: iOS never reveals read permission; we report the request and what data arrived.
        let supported = env.healthSync.readableTypes().count
        checks.append(Check(name: "healthkit_types_readable", ok: supported > 150,
                            detail: "\(supported) of \(HealthTypeCatalog.sampleTypes.count) catalog types exist on this OS"))
        if let auth = (try? db.preference("health_auth", as: HealthAuthResult.self)) ?? nil {
            checks.append(Check(name: "health_authorization_request", ok: auth.requestedTypes > 0,
                                detail: "\(auth.requestedTypes) types requested" +
                                    (auth.droppedKinds.isEmpty ? "" : ", dropped: \(auth.droppedKinds.joined(separator: ","))") +
                                    (auth.errors.isEmpty ? "" : " — errors: \(auth.errors.joined(separator: " | "))")))
        }
        let failures = await env.healthSync.lastFailures
        checks.append(Check(name: "healthkit_types_failing", ok: failures.isEmpty,
                            detail: failures.isEmpty ? "none" : "\(failures.count): \(failures.prefix(5).joined(separator: "; "))"))
        let labels = (try? db.labelCounts()) ?? []
        checks.append(Check(name: "healthkit_data_arrived", ok: labels.contains { $0.label == "heart_rate" } && labels.contains { $0.label == "step_count" },
                            detail: "\(labels.count) labels, \(labels.reduce(0) { $0 + $1.count }) samples"))
        let syncs = (try? await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT hk_type, last_sync_ts, backfill_done FROM sync_state").map {
                (LabelMapper.label(for: $0["hk_type"]), $0["last_sync_ts"] as Double?, ($0["backfill_done"] as Int) == 1)
            }
        }) ?? []
        let done = syncs.filter(\.2).count
        checks.append(Check(name: "backfill_done", ok: done >= supported && supported > 0, detail: "\(done)/\(supported) types"))
        for id in HealthTypeCatalog.backgroundDelivery {
            let label = LabelMapper.label(for: id)
            let last = syncs.first { $0.0 == label }?.1
            checks.append(Check(name: "last_sync_\(label)", ok: last.map { now - $0 < 6 * 3600 } ?? false,
                                detail: last.map { Self.ago(now - $0) } ?? "never"))
        }
        let registered = env.log.count("bg_registered"), fired = env.log.count("bg_delivery")
        checks.append(Check(name: "background_delivery_registered", ok: registered >= HealthTypeCatalog.backgroundDelivery.count,
                            detail: "\(registered) observer queries this launch"))
        checks.append(Check(name: "background_delivery_fired", ok: fired > 0,
                            detail: "\(fired) HealthKit wakes since launch (needs time in the background; check again tomorrow)"))
        metrics["bg_delivery_wakes_since_launch"] = Double(fired)

        // Location.
        checks.append(Check(name: "location_always", ok: env.location.authorization == .always,
                            detail: env.location.authorization.rawValue))
        let fences = await env.location.monitoredIdentifiers()
        let placeCount = ((try? env.places.places(includeSuggested: false)) ?? []).count
        checks.append(Check(name: "geofences", ok: fences.count == min(placeCount, PlaceService.maxGeofences) && placeCount > 0,
                            detail: "\(fences.count) monitored for \(placeCount) places"))
        let visits = (try? db.count("SELECT COUNT(*) FROM context_visits WHERE arrival_ts > \(now - 86400)")) ?? 0
        checks.append(Check(name: "visits_last_24h", ok: visits > 0, detail: "\(visits)"))
        let motion = (try? db.count("SELECT COUNT(*) FROM context_motion WHERE start_ts > \(now - 86400)")) ?? 0
        checks.append(Check(name: "phone_motion_last_24h", ok: motion > 0, detail: "\(motion) segments"))

        // Watch.
        checks.append(Check(name: "watch_paired_app_installed", ok: env.watchLink.isPaired, detail: env.watchLink.isPaired ? "yes" : "no"))
        checks.append(Check(name: "watch_reachable_now", ok: env.watchLink.isReachable, detail: env.watchLink.isReachable ? "yes" : "no (normal when the watch app isn't open)"))
        let cov = (try? env.watchImporter.coverage(hours: 24)) ?? (minutes: 0, of: 1440)
        metrics["raw_accel_coverage_24h_pct"] = Double(cov.minutes) / Double(cov.of) * 100
        checks.append(Check(name: "raw_coverage_24h", ok: cov.minutes > 0,
                            detail: String(format: "%d of %d minutes (%.0f %%)", cov.minutes, cov.of, metrics["raw_accel_coverage_24h_pct"]!)))
        if let ratio = compressionRatio() {
            metrics["raw_compression_ratio_vs_float32"] = ratio
            checks.append(Check(name: "raw_compression_ratio", ok: ratio > 1.5, detail: String(format: "%.2f× vs float32 (real data)", ratio)))
        }
        let gaps = ((try? db.preference("raw_gap_log", as: [[Double]].self)) ?? nil) ?? []
        let gapMin = gaps.filter { $0[1] > now - 86400 }.reduce(0) { $0 + ($1[1] - $1[0]) / 60 }
        metrics["recorder_gap_minutes_24h"] = gapMin
        checks.append(Check(name: "recorder_gaps_24h", ok: true, detail: String(format: "%.0f min in %d spans (measured, not worked around)", gapMin, gaps.count)))
        let snaps = (try? db.count("SELECT COUNT(DISTINCT minute_id) FROM raw_chunks WHERE tier = 2 AND minute_id > \(MinuteID.from(now - 86400))")) ?? 0
        checks.append(Check(name: "snapshots_24h", ok: snaps > 0, detail: "\(snaps) tier-2 snapshots"))
        let compass = (try? db.count("SELECT COUNT(*) FROM raw_chunks WHERE sensor = 'compass'")) ?? 0
        checks.append(Check(name: "compass_chunks", ok: compass > 0, detail: "\(compass) (magnetometer heading, no watch location)"))

        // Engine.
        let lastRun = env.engine.history().first
        checks.append(Check(name: "engine_last_run", ok: lastRun?.ok ?? false,
                            detail: lastRun.map { "\($0.trigger) on \($0.location ?? "phone"), \(Self.ago(now - $0.ts)) ago, \(String(format: "%.1f", $0.seconds)) s\($0.error.map { " — \($0)" } ?? "")" } ?? "never"))
        if let s = EmbeddedPython.shared.startupSeconds { metrics["python_startup_s"] = s }
        let plan = try? await env.windDown.latestPlan()
        let pending = await env.notifications.pending()
        let tonight = plan.map { p in pending.first { $0.identifier == WindDownScheduler.identifier(p.nightOf) } } ?? nil
        checks.append(Check(name: "tonight_notification_scheduled", ok: tonight != nil || (plan?.start ?? .distantFuture) < env.clock.now,
                            detail: tonight?.fireDate.map { "at \($0.formatted(date: .omitted, time: .shortened))" }
                                ?? (plan == nil ? "no plan" : "not pending (already due or delivered)")))
        let delays = (try? await env.windDown.delays()) ?? []
        if !delays.isEmpty {
            let d = delays.map(\.seconds)
            metrics["notification_delay_max_s"] = d.max()!
            metrics["notification_delay_mean_s"] = d.reduce(0, +) / Double(d.count)
            checks.append(Check(name: "notification_delay", ok: d.max()! <= 300,
                                detail: String(format: "%d delivered, max %.0f s, mean %.0f s (target ≤ 300 s)", d.count, d.max()!, metrics["notification_delay_mean_s"]!)))
        }

        // Server, Claude, signing.
        let reachable = await env.server.reachable()
        checks.append(Check(name: "server_reachable", ok: reachable, detail: env.server.baseURL?.host() ?? "not configured"))
        checks.append(Check(name: "claude_key_present", ok: env.secrets.get(SecretKey.anthropicKey)?.isEmpty == false,
                            detail: "model \(env.claudeModel)"))
        if let exp = SigningExpiry.expirationDate() {
            let days = SigningExpiry.daysLeft(exp, now: env.clock.now)
            metrics["signing_days_left"] = Double(days)
            checks.append(Check(name: "signing_expiry", ok: days >= 1, detail: "\(days) days (\(exp.formatted(date: .abbreviated, time: .shortened)))"))
        } else {
            checks.append(Check(name: "signing_expiry", ok: false, detail: "no embedded provisioning profile"))
        }
        let exportRows = (try? db.count("SELECT COUNT(*) FROM processed_samples WHERE hk_uuid LIKE 'export:%'")) ?? 0
        metrics["unadopted_export_rows"] = Double(exportRows)
        metrics["db_bytes"] = Double((try? FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int) ?? 0)
        metrics["app_bundle_bytes"] = Double(Self.directorySize(Bundle.main.bundleURL))
        metrics["phone_battery_pct"] = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return Double(UIDevice.current.batteryLevel * 100)
        }

        let device = await MainActor.run { UIDevice.current.model + " " + UIDevice.current.systemVersion }
        return Report(generatedAt: now, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                      device: device, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                      timeZone: env.timeZone.identifier, checks: checks, metrics: metrics)
    }

    /// Real compression ratio of stored chunks (spec §7.3, measured in the final test).
    func compressionRatio() -> Double? {
        let base = "FROM raw_chunks WHERE payload IS NOT NULL AND sensor = 'accel'"
        guard let f = try? env.db.count("SELECT COALESCE(SUM(sample_count * axes * 4), 0) \(base)"),
              let z = try? env.db.count("SELECT COALESCE(SUM(LENGTH(payload)), 0) \(base)"), z > 0 else { return nil }
        return Double(f) / Double(z)
    }

    func upload(_ report: Report) async throws {
        let data = try JSONEncoder.sortedKeys.encode(report)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        _ = try await env.server.client().post("diagnostics", obj)
    }

    static func ago(_ s: Double) -> String {
        s < 120 ? "\(Int(s)) s" : s < 7200 ? "\(Int(s / 60)) min" : s < 172800 ? "\(Int(s / 3600)) h" : "\(Int(s / 86400)) d"
    }

    static func directorySize(_ url: URL) -> Int {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let f = e?.nextObject() as? URL { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}
