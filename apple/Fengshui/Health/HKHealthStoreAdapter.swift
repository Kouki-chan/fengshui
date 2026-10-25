import CoreLocation
import Foundation
import HealthKit

/// The real HealthKit implementation of `HealthStore`.
final class HKHealthStoreAdapter: HealthStore, @unchecked Sendable {
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Type resolution

    static func objectType(_ t: HealthTypeInfo) -> HKObjectType? {
        switch t.kind {
        case .quantity: HKObjectType.quantityType(forIdentifier: .init(rawValue: t.identifier))
        case .category: HKObjectType.categoryType(forIdentifier: .init(rawValue: t.identifier))
        case .characteristic: HKObjectType.characteristicType(forIdentifier: .init(rawValue: t.identifier))
        case .scoredAssessment: HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: t.identifier))
        case .workout: HKObjectType.workoutType()
        case .series:
            t.identifier == "HKWorkoutRouteTypeIdentifier" ? HKSeriesType.workoutRoute() : HKSeriesType.heartbeat()
        case .stateOfMind: HKObjectType.stateOfMindType()
        case .audiogram: HKObjectType.audiogramSampleType()
        case .electrocardiogram: HKObjectType.electrocardiogramType()
        case .correlation, .document: nil
        }
    }

    func supportedTypes(_ types: [HealthTypeInfo]) -> [HealthTypeInfo] {
        types.filter { Self.objectType($0) != nil }
    }

    func requestAuthorization(read types: [HealthTypeInfo]) async throws -> HealthAuthResult {
        // Characteristics (date of birth, sex…) are read too; the engine uses age for max HR.
        let chars = HealthTypeCatalog.all.filter { $0.kind == .characteristic }
        let all = types + chars
        // If HealthKit rejects the request (e.g. a type it won't authorize on this device),
        // retry with fewer kinds so the permission sheet still appears.
        let special: Set<HealthTypeInfo.Kind> = [.stateOfMind, .scoredAssessment, .audiogram, .electrocardiogram]
        let attempts: [(dropped: [String], types: [HealthTypeInfo])] = [
            ([], all),
            (special.map(\.rawValue).sorted(), all.filter { !special.contains($0.kind) }),
            (["series"] + special.map(\.rawValue).sorted(),
             all.filter { [.quantity, .category, .workout, .characteristic].contains($0.kind) }),
        ]
        var errors: [String] = []
        for a in attempts {
            let read = Set(a.types.compactMap(Self.objectType))
            do {
                // Share only workouts: the watch saves tier-3 sessions as workouts (spec §6.1).
                try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: read)
                return HealthAuthResult(requestedTypes: read.count, droppedKinds: a.dropped, errors: errors)
            } catch {
                errors.append("\(read.count) types: \(error.localizedDescription)")
            }
        }
        throw NSError(domain: "Fengshui", code: 1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: " | ")])
    }

    // MARK: Anchored queries

    func fetch(_ type: HealthTypeInfo, anchor: Data?, limit: Int) async throws -> HealthPage {
        guard let sampleType = Self.objectType(type) as? HKSampleType else {
            return HealthPage(samples: [], deletedUUIDs: [], anchor: anchor, hasMore: false)
        }
        let hkAnchor = anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let units = await preferredUnits(for: [type])
        let (samples, deleted, newAnchor): ([HKSample], [HKDeletedObject], HKQueryAnchor?) =
            try await withCheckedThrowingContinuation { cont in
                let q = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: hkAnchor, limit: limit) {
                    _, samples, deleted, newAnchor, error in
                    if let error { cont.resume(throwing: error) } else {
                        cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor))
                    }
                }
                store.execute(q)
            }
        var rows: [HealthSample] = []
        rows.reserveCapacity(samples.count)
        for s in samples {
            if let row = try await convert(s, type: type, unit: units[type.identifier]) { rows.append(row) }
        }
        let data = try newAnchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return HealthPage(samples: rows, deletedUUIDs: deleted.map(\.uuid.uuidString), anchor: data ?? anchor,
                          hasMore: samples.count + deleted.count >= limit)
    }

    private func convert(_ s: HKSample, type: HealthTypeInfo, unit: String?) async throws -> HealthSample? {
        var row = HealthSample(uuid: s.uuid.uuidString, typeIdentifier: type.identifier, label: type.label,
                               value: nil, valueText: nil, unit: nil,
                               start: s.startDate.timeIntervalSince1970, end: s.endDate.timeIntervalSince1970,
                               sourceName: s.sourceRevision.source.name,
                               sourceBundle: s.sourceRevision.source.bundleIdentifier,
                               device: Self.describe(s.device), metadataJSON: nil)
        var meta = Self.jsonSafe(s.metadata ?? [:])
        switch s {
        case let q as HKQuantitySample:
            let u = unit.map { HKUnit(from: $0) }
            if let u, q.quantity.is(compatibleWith: u) {
                row.value = q.quantity.doubleValue(for: u)
                row.unit = u.unitString
            } else {
                // Never call doubleValue with an incompatible unit (it raises); keep the description.
                row.valueText = q.quantity.description
            }
        case let c as HKCategorySample:
            row.value = Double(c.value)
            row.valueText = LabelMapper.categoryText(type: type.identifier, rawValue: c.value)
        case let w as HKWorkout:
            row.value = w.duration
            row.unit = "s"
            row.valueText = LabelMapper.workoutActivityNames[w.workoutActivityType.rawValue]
                ?? "activity_\(w.workoutActivityType.rawValue)"
            var stats: [String: Any] = [:]
            for (qt, st) in w.allStatistics {
                let u = (await preferredUnits(for: [HealthTypeCatalog.info(qt.identifier)].compactMap { $0 }))[qt.identifier]
                if let u, let sum = st.sumQuantity(), sum.is(compatibleWith: HKUnit(from: u)) {
                    stats[LabelMapper.label(for: qt.identifier)] = ["sum": sum.doubleValue(for: HKUnit(from: u)), "unit": u]
                }
            }
            meta["statistics"] = stats
        case let h as HKHeartbeatSeriesSample:
            let beats = try await heartbeats(h)
            row.value = Double(beats.count)
            row.unit = "count"
            meta["beats"] = beats
        case let e as HKElectrocardiogram:
            row.value = Double(e.numberOfVoltageMeasurements)
            row.valueText = "classification_\(e.classification.rawValue)"
            meta["sampling_hz"] = e.samplingFrequency?.doubleValue(for: .hertz())
        case let m as HKStateOfMind:
            row.value = m.valence
            row.valueText = m.kind == .dailyMood ? "daily_mood" : "momentary_emotion"
            meta["labels"] = m.labels.map(\.rawValue)
            meta["associations"] = m.associations.map(\.rawValue)
        case let a as HKScoredAssessment:
            row.value = Double(a.score)
        case is HKAudiogramSample:
            row.valueText = "audiogram"
        default:
            break
        }
        if !meta.isEmpty, let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            row.metadataJSON = String(data: data, encoding: .utf8)
        }
        return row
    }

    private func heartbeats(_ series: HKHeartbeatSeriesSample) async throws -> [[Double]] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[Double]], Error>) in
            let beats = Accumulator<[Double]>()
            let q = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, sinceStart, precededByGap, done, error in
                if let error { cont.resume(throwing: error); return }
                beats.append([sinceStart, precededByGap ? 1 : 0])
                if done { cont.resume(returning: beats.items) }
            }
            store.execute(q)
        }
    }

    // MARK: Routes, characteristics, units

    func routePoints(workoutUUID: String) async throws -> [RoutePoint] {
        guard let uuid = UUID(uuidString: workoutUUID) else { return [] }
        let routes = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKWorkoutRoute], Error>) in
            let workoutPred = HKQuery.predicateForObject(with: uuid)
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: workoutPred, limit: 1, sortDescriptors: nil) {
                [store] _, workouts, error in
                guard let w = workouts?.first as? HKWorkout else { cont.resume(returning: []); return }
                if let error { cont.resume(throwing: error); return }
                let rq = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                       predicate: HKQuery.predicateForObjects(from: w), limit: HKObjectQueryNoLimit,
                                       sortDescriptors: nil) { _, routes, error in
                    if let error { cont.resume(throwing: error) } else {
                        cont.resume(returning: (routes as? [HKWorkoutRoute]) ?? [])
                    }
                }
                store.execute(rq)
            }
            store.execute(q)
        }
        var points: [RoutePoint] = []
        for r in routes {
            let locs: [CLLocation] = try await withCheckedThrowingContinuation { cont in
                let acc = Accumulator<CLLocation>()
                let q = HKWorkoutRouteQuery(route: r) { _, locations, done, error in
                    if let error { cont.resume(throwing: error); return }
                    for l in locations ?? [] { acc.append(l) }
                    if done { cont.resume(returning: acc.items) }
                }
                store.execute(q)
            }
            points += locs.map {
                RoutePoint(ts: $0.timestamp.timeIntervalSince1970, lat: $0.coordinate.latitude,
                           lon: $0.coordinate.longitude, altitude: $0.altitude,
                           speed: $0.speed >= 0 ? $0.speed : nil, horizontalAccuracy: $0.horizontalAccuracy)
            }
        }
        return points
    }

    func characteristics() async -> [String: String] {
        var out: [String: String] = [:]
        if let dob = try? store.dateOfBirthComponents(), let y = dob.year, let m = dob.month, let d = dob.day {
            out["date_of_birth"] = String(format: "%04d-%02d-%02d", y, m, d)
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            out["biological_sex"] = [.female: "female", .male: "male", .other: "other"][sex] ?? "not_set"
        }
        if let blood = try? store.bloodType().bloodType { out["blood_type"] = "raw_\(blood.rawValue)" }
        if let skin = try? store.fitzpatrickSkinType().skinType { out["skin_type"] = "raw_\(skin.rawValue)" }
        if let wc = try? store.wheelchairUse().wheelchairUse { out["wheelchair_use"] = "raw_\(wc.rawValue)" }
        return out
    }

    func preferredUnits(for types: [HealthTypeInfo]) async -> [String: String] {
        let qts = Set(types.compactMap { HKObjectType.quantityType(forIdentifier: .init(rawValue: $0.identifier)) })
        var out: [String: String] = [:]
        if !qts.isEmpty, let units = try? await store.preferredUnits(for: qts) {
            for (k, v) in units { out[k.identifier] = v.unitString }
        }
        // Spec §6.1: fall back to a sensible default per type.
        for t in types where out[t.identifier] == nil {
            if let u = HealthTypeCatalog.unit(for: t) { out[t.identifier] = u }
        }
        return out
    }

    // MARK: Background delivery

    func observe(_ type: HealthTypeInfo, onChange: @escaping @Sendable () async -> Void) async throws {
        guard let sampleType = Self.objectType(type) as? HKSampleType else { return }
        let q = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            // HealthKit's completion handler isn't marked Sendable; it must be called
            // exactly once after our sync, from any thread.
            nonisolated(unsafe) let done = completion
            Task {
                await onChange()
                done()
            }
        }
        store.execute(q)
        try await store.enableBackgroundDelivery(for: sampleType, frequency: .immediate)
    }

    // MARK: Helpers

    static func describe(_ d: HKDevice?) -> String? {
        guard let d else { return nil }
        // Same field layout as the Health export (without the pointer), see importer.clean_device.
        let parts: [(String, String?)] = [("name", d.name), ("manufacturer", d.manufacturer), ("model", d.model),
                                          ("hardware", d.hardwareVersion), ("software", d.softwareVersion)]
        let s = parts.compactMap { k, v in v.map { "\(k):\($0)" } }.joined(separator: ", ")
        return s.isEmpty ? nil : s
    }

    /// Thread-safe collector for HealthKit's streaming query callbacks.
    final class Accumulator<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [T] = []
        func append(_ x: T) { lock.lock(); storage.append(x); lock.unlock() }
        var items: [T] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    static func jsonSafe(_ dict: [String: Any]) -> [String: Any] {
        dict.mapValues { v -> Any in
            switch v {
            case let n as NSNumber: n
            case let s as String: s
            case let d as Date: d.timeIntervalSince1970
            case let q as HKQuantity: q.description
            default: String(describing: v)
            }
        }
    }
}
