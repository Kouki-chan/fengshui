import Foundation

/// A synthetic scenario written by engine/tests/synth.py (fixtures/scenarios/<name>.json).
/// Swift fakes load the same files as the Python tests (spec §14.1).
struct Scenario: Sendable {
    struct Place: Decodable, Sendable { let name: String; let kind: String; let lat: Double; let lon: Double; let radius_m: Double }
    struct Workout: Decodable, Sendable {
        let uuid: String; let activity: String; let start: Double; let end: Double
        let energy_kcal: Double; let distance_m: Double; let source: String; let route: [[Double]]
    }
    struct Motion: Sendable { let start: Double; let end: Double; let activity: String; let confidence: Int }
    struct Visit: Sendable { let arrival: Double; let departure: Double?; let lat: Double; let lon: Double; let hAccuracy: Double }

    let name: String
    let tz: String
    let now: Double
    let characteristics: [String: String]
    let onboarding: [String: String]
    let places: [Place]
    let samples: [HealthSample]
    let workouts: [Workout]
    let motion: [Motion]
    let visits: [Visit]
    let rawPlan: [(start: Double, end: Double, kind: String)]

    static func load(_ name: String, bundle: Bundle = .main) throws -> Scenario {
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "scenarios")
            ?? Self.repoURL(name)
        return try decode(Data(contentsOf: url))
    }

    /// Unit tests can read the repo directly (the simulator shares the Mac's file system).
    static func repoURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/scenarios/\(name).json")
    }

    static func decode(_ data: Data) throws -> Scenario {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func str(_ v: Any?) -> String? { v as? String }
        let samples: [HealthSample] = (j["samples"] as? [[Any]] ?? []).map { r in
            let type = r[1] as! String
            var meta: String?
            if let m = r[10] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: m, options: .sortedKeys) {
                meta = String(data: d, encoding: .utf8)
            }
            return HealthSample(uuid: r[0] as! String, typeIdentifier: type, label: LabelMapper.label(for: type),
                                value: num(r[2]), valueText: str(r[3]), unit: str(r[4]), start: num(r[5])!,
                                end: num(r[6])!, sourceName: str(r[7]), sourceBundle: str(r[8]), device: str(r[9]),
                                metadataJSON: meta)
        }
        let dec = JSONDecoder()
        let places = try dec.decode([Place].self, from: JSONSerialization.data(withJSONObject: j["places"] ?? []))
        let workouts = try dec.decode([Workout].self, from: JSONSerialization.data(withJSONObject: j["workouts"] ?? []))
        let motion = (j["motion"] as? [[Any]] ?? []).map {
            Motion(start: num($0[0])!, end: num($0[1])!, activity: $0[2] as! String, confidence: ($0[3] as! NSNumber).intValue)
        }
        let visits = (j["visits"] as? [[Any]] ?? []).map {
            Visit(arrival: num($0[0])!, departure: num($0[1]), lat: num($0[2])!, lon: num($0[3])!, hAccuracy: num($0[4]) ?? 30)
        }
        let raw = (j["raw_plan"] as? [[Any]] ?? []).map { (start: num($0[0])!, end: num($0[1])!, kind: $0[2] as! String) }
        return Scenario(name: j["name"] as! String, tz: j["tz"] as! String, now: num(j["now"])!,
                        characteristics: j["characteristics"] as? [String: String] ?? [:],
                        onboarding: j["onboarding"] as? [String: String] ?? [:], places: places,
                        samples: samples, workouts: workouts, motion: motion, visits: visits, rawPlan: raw)
    }
}
